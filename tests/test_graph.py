"""Tests for the graph knowledge store — nodes, edges, and simulation events.

No live database or LLM server required:
  - Neo4j driver/session calls are mocked
  - FakeLLMClient provides the in-memory vector store
"""
from __future__ import annotations

from datetime import timezone
from unittest.mock import AsyncMock

import pytest

from lib.core.config import Settings
from lib.graph.cypher import NEO4J_DATABASE
from lib.graph.events import (
    EDGE_AFFECTED_BY,
    SimulationEvent,
    get_affected_entities,
    inject_event,
    remove_event,
    remove_scenario,
)
from lib.graph.nodes import (
    create_dependency_edge,
    create_entity_node,
    delete_entity_node,
    get_dependent_entities,
)
from lib.llm.fake import FakeLLMClient
from tests.conftest import neo4j_driver_mock, neo4j_run_result


# ── Fixtures ──────────────────────────────────────────────────────────────────


def _settings() -> Settings:
    return Settings(
        postgres_dsn="postgresql://mock:mock@localhost/mock",
        llm_backend="fake",
        embedding_dimension=16,
    )


def _fake_client() -> FakeLLMClient:
    return FakeLLMClient(settings=_settings())


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


# ── Cypher helpers ────────────────────────────────────────────────────────────


def test_neo4j_database_is_canonical_name():
    assert NEO4J_DATABASE == "neo4j"


# ── Entity node operations ────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_create_entity_node_executes_cypher():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await create_entity_node(driver, "e1", "moving_entity")

    session.run.assert_awaited_once()
    query = session.run.call_args.args[0]
    kwargs = session.run.call_args.kwargs
    assert "MERGE" in query
    assert "Entity" in query
    assert kwargs["id"] == "e1"
    assert kwargs["type"] == "moving_entity"


@pytest.mark.asyncio
async def test_create_entity_node_accepts_attributes_without_error():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await create_entity_node(driver, "e2", "sensor", {"region": "west"})

    session.run.assert_awaited_once()


@pytest.mark.asyncio
async def test_delete_entity_node_executes_detach_delete():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await delete_entity_node(driver, "e1")

    query = session.run.call_args.args[0]
    kwargs = session.run.call_args.kwargs
    assert "DETACH DELETE" in query
    assert kwargs["id"] == "e1"


# ── Dependency edges ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_create_dependency_edge_uses_edge_type():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await create_dependency_edge(driver, "a", "b", "FEEDS")

    query = session.run.call_args.args[0]
    kwargs = session.run.call_args.kwargs
    assert "FEEDS" in query
    assert kwargs["from_id"] == "a"
    assert kwargs["to_id"] == "b"


@pytest.mark.asyncio
async def test_create_dependency_edge_default_type():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await create_dependency_edge(driver, "a", "b")

    query = session.run.call_args.args[0]
    assert "DEPENDS_ON" in query


@pytest.mark.asyncio
async def test_get_dependent_entities_returns_parsed_ids():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(
        return_value=neo4j_run_result(
            data=[{"dep_id": "dep-entity-1"}, {"dep_id": "dep-entity-2"}]
        )
    )

    deps = await get_dependent_entities(driver, "root-entity")

    assert deps == ["dep-entity-1", "dep-entity-2"]


@pytest.mark.asyncio
async def test_get_dependent_entities_empty():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result(data=[]))

    deps = await get_dependent_entities(driver, "isolated")

    assert deps == []


# ── SimulationEvent dataclass ─────────────────────────────────────────────────


def test_simulation_event_fields():
    evt = _event()
    assert evt.id == "evt-1"
    assert evt.scenario_id == "s1"
    assert "entity-A" in evt.affected_entity_ids
    assert evt.created_at.tzinfo is not None


def test_simulation_event_default_created_at_is_utc():
    evt = _event()
    assert evt.created_at.tzinfo == timezone.utc


# ── inject_event ──────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_inject_event_creates_event_node():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()
    evt = _event()

    await inject_event(evt, driver, client)

    queries = [c.args[0] for c in session.run.call_args_list]
    assert any("SimulationEvent" in query for query in queries)


@pytest.mark.asyncio
async def test_inject_event_creates_affected_by_edges():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()
    evt = _event(affected=["entity-A", "entity-B", "entity-C"])

    await inject_event(evt, driver, client)

    assert session.run.await_count == 4
    edge_calls = [
        c.args[0] for c in session.run.call_args_list if EDGE_AFFECTED_BY in c.args[0]
    ]
    assert len(edge_calls) == 3


@pytest.mark.asyncio
async def test_inject_event_embeds_description_in_vector_store():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()
    evt = _event()

    await inject_event(evt, driver, client)

    vdb = f"sim_events_{evt.scenario_id}"
    results = await client.vector_search(evt.description, vdb, top_k=1)
    assert len(results) == 1
    assert results[0].document_id == evt.id


@pytest.mark.asyncio
async def test_inject_event_chunk_metadata_contains_scenario_id():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()
    evt = _event()

    await inject_event(evt, driver, client)

    vdb = f"sim_events_{evt.scenario_id}"
    results = await client.vector_search(evt.description, vdb)
    assert results[0].metadata.get("scenario_id") == evt.scenario_id


@pytest.mark.asyncio
async def test_inject_multiple_events_same_scenario():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()

    evt1 = _event("evt-1", "s1", ["e1"])
    evt2 = _event("evt-2", "s1", ["e2"])

    await inject_event(evt1, driver, client)
    await inject_event(evt2, driver, client)

    vdb = "sim_events_s1"
    results = await client.vector_search("disruption", vdb, top_k=5)
    doc_ids = {r.document_id for r in results}
    assert "evt-1" in doc_ids
    assert "evt-2" in doc_ids


# ── get_affected_entities ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_affected_entities_returns_entity_ids():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(
        return_value=neo4j_run_result(
            data=[{"entity_id": "entity-A"}, {"entity_id": "entity-B"}]
        )
    )

    ids = await get_affected_entities(driver, "evt-1")

    assert ids == ["entity-A", "entity-B"]
    query = session.run.call_args.args[0]
    assert "AFFECTED_BY" in query
    assert "SimulationEvent" in query


@pytest.mark.asyncio
async def test_get_affected_entities_empty_when_no_edges():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result(data=[]))

    ids = await get_affected_entities(driver, "no-such-event")

    assert ids == []


# ── remove_event ──────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_remove_event_issues_detach_delete():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await remove_event("evt-1", driver)

    session.run.assert_awaited_once()
    query = session.run.call_args.args[0]
    kwargs = session.run.call_args.kwargs
    assert "DETACH DELETE" in query
    assert "SimulationEvent" in query
    assert kwargs["id"] == "evt-1"


@pytest.mark.asyncio
async def test_remove_event_does_not_touch_entity_nodes():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())

    await remove_event("evt-1", driver)

    query = session.run.call_args.args[0]
    assert "Entity" not in query.split("SimulationEvent")[0]


# ── remove_scenario ───────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_remove_scenario_cleans_graph_and_vector():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()
    evt = _event(scenario_id="s2")

    await inject_event(evt, driver, client)
    vdb = f"sim_events_{evt.scenario_id}"

    pre = await client.vector_search(evt.description, vdb)
    assert len(pre) > 0

    session.run.reset_mock()
    await remove_scenario(evt.scenario_id, driver, client)

    session.run.assert_awaited_once()
    query = session.run.call_args.args[0]
    kwargs = session.run.call_args.kwargs
    assert "DETACH DELETE" in query
    assert kwargs["sid"] == evt.scenario_id

    post = await client.vector_search(evt.description, vdb)
    assert post == []


@pytest.mark.asyncio
async def test_remove_scenario_does_not_affect_other_scenarios():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()

    evt_s1 = _event("evt-s1", "scenario-one", ["e1"])
    evt_s2 = _event("evt-s2", "scenario-two", ["e2"])

    await inject_event(evt_s1, driver, client)
    await inject_event(evt_s2, driver, client)

    session.run.reset_mock()
    await remove_scenario("scenario-one", driver, client)

    results = await client.vector_search(
        evt_s2.description, "sim_events_scenario-two"
    )
    assert len(results) > 0


# ── Full round-trip: inject → query → remove ─────────────────────────────────


@pytest.mark.asyncio
async def test_full_roundtrip_inject_remove():
    driver, session = neo4j_driver_mock()
    session.run = AsyncMock(return_value=neo4j_run_result())
    client = _fake_client()
    evt = _event("evt-rt", "rt-scenario", ["e1", "e2"])

    await inject_event(evt, driver, client)
    assert session.run.await_count == 3

    vdb = "sim_events_rt-scenario"
    hits = await client.vector_search(evt.description, vdb, top_k=1)
    assert hits[0].document_id == "evt-rt"

    session.run.reset_mock()
    await remove_scenario(evt.scenario_id, driver, client)

    assert session.run.await_count == 1
    delete_query = session.run.call_args.args[0]
    assert "DETACH DELETE" in delete_query

    post_hits = await client.vector_search(evt.description, vdb)
    assert post_hits == []
