"""Tests for the Neo4j graph knowledge store — nodes, edges, and events.

No live database or LLM server required:
  - Neo4j driver sessions are mocked
  - FakeLLMClient provides the in-memory vector store
"""
from __future__ import annotations

from datetime import timezone
from unittest.mock import AsyncMock, MagicMock

import pytest

from src.core.config import Settings
from src.graph.cypher import NEO4J_DATABASE
from src.graph.events import (
    EDGE_AFFECTED_BY,
    SimulationEvent,
    get_affected_entities,
    inject_event,
    remove_event,
    remove_scenario,
)
from src.graph.nodes import (
    create_dependency_edge,
    create_entity_node,
    delete_entity_node,
    get_dependent_entities,
)
from src.llm.fake import FakeLLMClient


def _settings() -> Settings:
    return Settings(
        postgres_dsn="postgresql://mock:mock@localhost/mock",
        llm_backend="fake",
        embedding_dimension=16,
    )


def _fake_client() -> FakeLLMClient:
    return FakeLLMClient(settings=_settings())


def _neo4j_session() -> tuple[MagicMock, AsyncMock]:
    """Return (driver, session) with async context manager wiring."""
    session = AsyncMock()
    result = AsyncMock()
    result.single = AsyncMock(return_value=None)
    result.data = AsyncMock(return_value=[])
    session.run = AsyncMock(return_value=result)

    cm = AsyncMock()
    cm.__aenter__ = AsyncMock(return_value=session)
    cm.__aexit__ = AsyncMock(return_value=False)

    driver = MagicMock()
    driver.session.return_value = cm
    return driver, session


def _event(
    event_id: str = "evt-1",
    scenario_id: str = "s1",
    affected: list[str] | None = None,
) -> SimulationEvent:
    return SimulationEvent(
        id=event_id,
        scenario_id=scenario_id,
        description="A major disruption affecting downstream entities.",
        affected_entity_ids=affected or ["entity-A", "entity-B"],
        attributes={"severity": "high"},
    )


def test_neo4j_database_constant():
    assert NEO4J_DATABASE == "neo4j"


@pytest.mark.asyncio
async def test_create_entity_node_runs_merge_cypher():
    driver, session = _neo4j_session()
    await create_entity_node(driver, "e1", "moving_entity")
    driver.session.assert_called_once_with(database=NEO4J_DATABASE)
    query = session.run.call_args.args[0]
    assert "MERGE" in query
    assert "Entity" in query
    assert session.run.call_args.kwargs["id"] == "e1"


@pytest.mark.asyncio
async def test_delete_entity_node_runs_detach_delete():
    driver, session = _neo4j_session()
    await delete_entity_node(driver, "e1")
    query = session.run.call_args.args[0]
    assert "DETACH DELETE" in query
    assert session.run.call_args.kwargs["id"] == "e1"


@pytest.mark.asyncio
async def test_create_dependency_edge_uses_edge_type():
    driver, session = _neo4j_session()
    await create_dependency_edge(driver, "a", "b", "FEEDS")
    query = session.run.call_args.args[0]
    assert "FEEDS" in query
    kwargs = session.run.call_args.kwargs
    assert kwargs["from_id"] == "a"
    assert kwargs["to_id"] == "b"


@pytest.mark.asyncio
async def test_get_dependent_entities_returns_ids():
    driver, session = _neo4j_session()
    session.run.return_value.data = AsyncMock(
        return_value=[{"dep_id": "dep-1"}, {"dep_id": "dep-2"}]
    )
    deps = await get_dependent_entities(driver, "root-entity")
    assert deps == ["dep-1", "dep-2"]


def test_simulation_event_fields():
    evt = _event()
    assert evt.id == "evt-1"
    assert evt.scenario_id == "s1"
    assert "entity-A" in evt.affected_entity_ids
    assert evt.created_at.tzinfo is not None


def test_simulation_event_default_created_at_is_utc():
    evt = _event()
    assert evt.created_at.tzinfo == timezone.utc


@pytest.mark.asyncio
async def test_inject_event_creates_graph_and_vector_entries():
    driver, session = _neo4j_session()
    client = _fake_client()
    evt = _event(affected=["entity-A", "entity-B"])

    await inject_event(evt, driver, client)

    queries = [c.args[0] for c in session.run.call_args_list]
    assert any("SimulationEvent" in q for q in queries)
    assert sum(EDGE_AFFECTED_BY in q for q in queries) == 2

    vdb = f"sim_events_{evt.scenario_id}"
    results = await client.vector_search(evt.description, vdb, top_k=1)
    assert len(results) == 1
    assert results[0].document_id == evt.id


@pytest.mark.asyncio
async def test_get_affected_entities_returns_entity_ids():
    driver, session = _neo4j_session()
    session.run.return_value.data = AsyncMock(
        return_value=[{"entity_id": "entity-A"}, {"entity_id": "entity-B"}]
    )
    ids = await get_affected_entities(driver, "evt-1")
    assert ids == ["entity-A", "entity-B"]
    query = session.run.call_args.args[0]
    assert EDGE_AFFECTED_BY in query
    assert "SimulationEvent" in query


@pytest.mark.asyncio
async def test_remove_event_issues_detach_delete():
    driver, session = _neo4j_session()
    await remove_event("evt-1", driver)
    query = session.run.call_args.args[0]
    assert "DETACH DELETE" in query
    assert session.run.call_args.kwargs["id"] == "evt-1"


@pytest.mark.asyncio
async def test_remove_scenario_cleans_graph_and_vector():
    driver, session = _neo4j_session()
    client = _fake_client()
    evt = _event(scenario_id="s2")
    await inject_event(evt, driver, client)
    vdb = f"sim_events_{evt.scenario_id}"
    assert await client.vector_search(evt.description, vdb)

    await remove_scenario("s2", driver, client)

    delete_query = session.run.call_args_list[-1].args[0]
    assert "scenario_id" in delete_query
    assert await client.vector_search(evt.description, vdb) == []
