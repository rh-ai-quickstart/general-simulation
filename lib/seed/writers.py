"""Shared Postgres + Neo4j writers for demo and YAML overlay seeding."""
from __future__ import annotations

import logging
from typing import Any

import asyncpg
from neo4j import AsyncDriver, AsyncGraphDatabase

from lib.core.config import Settings
from lib.core.db import create_pool
from lib.core.ingestion import CanonicalEntity
from lib.graph.nodes import EDGE_CARRIES, merge_dependency_edges
from lib.graph.spatial_overlay import sync_event_affected_from_bbox
from lib.importers.network_yaml import Neo4jEntityWrite, NetworkSeedBundle
from lib.ingestion.runner import _insert_state, _upsert_entity

logger = logging.getLogger(__name__)


async def upsert_entities_to_postgres(
    settings: Settings,
    entities: list[CanonicalEntity],
) -> None:
    """Upsert canonical entities into PostGIS live store."""
    if not entities:
        logger.info("No entities to upsert into Postgres.")
        return

    pool = await create_pool(settings)
    try:
        async with pool.acquire() as conn:
            async with conn.transaction():
                for entity in entities:
                    await _upsert_entity(conn, entity)
                    await _insert_state(conn, entity)
                    logger.info("  ✓ Postgres %s (%s)", entity.id, entity.type)
    finally:
        await pool.close()
    logger.info("Postgres upsert complete: %d entities", len(entities))


async def write_network_bundle_to_neo4j(
    settings: Settings,
    bundle: NetworkSeedBundle,
) -> None:
    """MERGE rich Entity nodes, CARRIES, and dependency edges from a bundle."""
    if not bundle.neo4j_entities and not bundle.dependency_edges:
        logger.info("No Neo4j graph updates in bundle.")
        return

    driver = AsyncGraphDatabase.driver(
        settings.neo4j_uri,
        auth=(settings.neo4j_user, settings.neo4j_password),
    )
    try:
        async with driver.session(database="neo4j") as session:
            for node in bundle.neo4j_entities:
                await _merge_entity_with_props(session, node)

            for carrier_id, cargo_id in bundle.carries_edges:
                await session.run(
                    "MATCH (carrier:Entity {id: $carrier_id}), "
                    "      (cargo:Entity {id: $cargo_id}) "
                    f"MERGE (carrier)-[:{EDGE_CARRIES}]->(cargo)",
                    carrier_id=carrier_id,
                    cargo_id=cargo_id,
                )
                logger.info("  ✓ %s -[%s]-> %s", carrier_id, EDGE_CARRIES, cargo_id)

        if bundle.dependency_edges:
            edges = [
                {"from_id": f, "to_id": t, "edge_type": e}
                for f, t, e in bundle.dependency_edges
            ]
            merged = await merge_dependency_edges(driver, edges)
            logger.info("Dependency edges merged: %d", merged)
    finally:
        await driver.close()


async def inject_scenarios(
    settings: Settings,
    scenarios: list[dict[str, Any]],
) -> None:
    """MERGE SimulationEvent overlay nodes."""
    if not scenarios:
        return

    driver = AsyncGraphDatabase.driver(
        settings.neo4j_uri,
        auth=(settings.neo4j_user, settings.neo4j_password),
    )
    try:
        async with driver.session(database="neo4j") as session:
            for scenario in scenarios:
                await session.run(
                    "MERGE (e:SimulationEvent {id: $id}) "
                    "SET e.scenario_id = $scenario_id, "
                    "    e.description = $description, "
                    "    e.affect_bbox = $bbox",
                    id=scenario["event_id"],
                    scenario_id=scenario["scenario_id"],
                    description=str(scenario["description"])[:200],
                    bbox=scenario["bbox"],
                )
                logger.info(
                    "  ✓ SimulationEvent %s (%s)",
                    scenario["event_id"],
                    scenario["scenario_id"],
                )
    finally:
        await driver.close()


async def sync_scenario_overlays(
    settings: Settings,
    scenarios: list[dict[str, Any]],
) -> None:
    """Wire AFFECTED_BY from PostGIS bbox for each scenario event."""
    if not scenarios:
        return

    pool = await create_pool(settings)
    driver = AsyncGraphDatabase.driver(
        settings.neo4j_uri,
        auth=(settings.neo4j_user, settings.neo4j_password),
    )
    try:
        for scenario in scenarios:
            affected = await sync_event_affected_from_bbox(
                driver,
                pool,
                event_id=scenario["event_id"],
                bbox=scenario["bbox"],
            )
            logger.info(
                "Spatial overlay synced: %d entities in scenario %s",
                len(affected),
                scenario["scenario_id"],
            )
    finally:
        await driver.close()
        await pool.close()


async def write_network_overlay(
    settings: Settings,
    bundle: NetworkSeedBundle,
) -> None:
    """Full overlay write: Postgres, Neo4j graph, scenarios, spatial sync."""
    if not bundle.ok:
        errors = [i.message for i in bundle.issues if i.level == "error"]
        raise ValueError(
            f"Cannot commit network overlay with {bundle.error_count} error(s): "
            + "; ".join(errors[:5])
        )

    await upsert_entities_to_postgres(settings, bundle.entities)
    await write_network_bundle_to_neo4j(settings, bundle)
    await inject_scenarios(settings, bundle.scenarios)
    await sync_scenario_overlays(settings, bundle.scenarios)


async def _merge_entity_with_props(session: Any, node: Neo4jEntityWrite) -> None:
    """MERGE an Entity node and SET type + non-null props."""
    props = {k: v for k, v in node.props.items() if v is not None}
    set_clauses = ["n.type = $type"]
    params: dict[str, Any] = {"id": node.id, "type": node.type}
    for index, (key, value) in enumerate(props.items()):
        param = f"p{index}"
        set_clauses.append(f"n.{key} = ${param}")
        params[param] = value

    query = (
        "MERGE (n:Entity {id: $id}) "
        f"SET {', '.join(set_clauses)} "
        "RETURN id(n)"
    )
    await session.run(query, **params)
    logger.info("  ✓ Neo4j %s (%s)", node.id, node.type)
