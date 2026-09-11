"""Smoke tests for the schema bootstrap.

All database I/O is mocked — no live Postgres or Neo4j required.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from lib.graph.bootstrap import (
    _EXTENSION_STATEMENTS,
    _NEO4J_CONSTRAINTS,
    _NEO4J_INDEXES,
    _TABLE_STATEMENTS,
    bootstrap,
    bootstrap_neo4j,
    bootstrap_postgres,
)
from tests.conftest import neo4j_driver_mock


def _make_conn_mock() -> AsyncMock:
    """Return an AsyncMock that acts like an asyncpg.Connection."""
    conn = AsyncMock()
    tx = AsyncMock()
    tx.__aenter__ = AsyncMock(return_value=tx)
    tx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=tx)
    return conn


@pytest.mark.asyncio
async def test_bootstrap_postgres_calls_all_extension_statements():
    conn = _make_conn_mock()
    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    executed = [c.args[0].strip() for c in conn.execute.call_args_list]

    for stmt in _EXTENSION_STATEMENTS:
        assert stmt.strip() in executed, f"Expected '{stmt.strip()}' to be executed"


@pytest.mark.asyncio
async def test_bootstrap_postgres_creates_all_tables():
    conn = _make_conn_mock()
    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    executed = "\n".join(c.args[0] for c in conn.execute.call_args_list)

    assert "CREATE TABLE IF NOT EXISTS entity" in executed
    assert "CREATE TABLE IF NOT EXISTS entity_state" in executed


@pytest.mark.asyncio
async def test_bootstrap_postgres_creates_indexes():
    conn = _make_conn_mock()
    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    executed = "\n".join(c.args[0] for c in conn.execute.call_args_list)

    assert "idx_entity_type" in executed
    assert "idx_entity_geometry" in executed
    assert "idx_entity_state_entity" in executed
    assert "idx_entity_state_time" in executed


@pytest.mark.asyncio
async def test_bootstrap_postgres_closes_connection_on_success():
    conn = _make_conn_mock()
    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    conn.close.assert_awaited_once()


@pytest.mark.asyncio
async def test_bootstrap_postgres_closes_connection_on_error():
    conn = _make_conn_mock()
    conn.execute.side_effect = [None, RuntimeError("db error")]

    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        with pytest.raises(RuntimeError, match="db error"):
            await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    conn.close.assert_awaited_once()


@pytest.mark.asyncio
async def test_bootstrap_neo4j_runs_constraints_and_indexes():
    driver, session = neo4j_driver_mock()

    await bootstrap_neo4j(driver)

    executed = [c.args[0] for c in session.run.call_args_list]
    for stmt in _NEO4J_CONSTRAINTS + _NEO4J_INDEXES:
        assert stmt in executed


@pytest.mark.asyncio
async def test_bootstrap_calls_postgres_and_neo4j():
    conn = _make_conn_mock()
    driver, session = neo4j_driver_mock()

    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap("postgresql://mock:mock@localhost/mock", driver)

    assert conn.execute.await_count > 0
    assert session.run.await_count == len(_NEO4J_CONSTRAINTS) + len(_NEO4J_INDEXES)
    conn.close.assert_awaited_once()
