"""Smoke tests for the schema bootstrap.

All database I/O is mocked — no live Postgres or Neo4j required.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.graph.bootstrap import (
    _EXTENSION_STATEMENTS,
    _NEO4J_CONSTRAINTS,
    _TABLE_STATEMENTS,
    bootstrap_neo4j,
    bootstrap_postgres,
)


def _make_conn_mock() -> AsyncMock:
    conn = AsyncMock()
    tx = AsyncMock()
    tx.__aenter__ = AsyncMock(return_value=tx)
    tx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=tx)
    return conn


@pytest.mark.asyncio
async def test_bootstrap_postgres_calls_extension_statements():
    conn = _make_conn_mock()
    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    executed = [c.args[0].strip() for c in conn.execute.call_args_list]
    for stmt in _EXTENSION_STATEMENTS:
        assert stmt.strip() in executed


@pytest.mark.asyncio
async def test_bootstrap_postgres_creates_tables_and_indexes():
    conn = _make_conn_mock()
    with patch("asyncpg.connect", new_callable=AsyncMock, return_value=conn):
        await bootstrap_postgres("postgresql://mock:mock@localhost/mock")

    executed = "\n".join(c.args[0] for c in conn.execute.call_args_list)
    assert "CREATE TABLE IF NOT EXISTS entity" in executed
    assert "CREATE TABLE IF NOT EXISTS entity_state" in executed
    assert "idx_entity_type" in executed
    assert "idx_entity_geometry" in executed


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
async def test_bootstrap_neo4j_applies_constraints():
    session = AsyncMock()
    session.run = AsyncMock()
    cm = AsyncMock()
    cm.__aenter__ = AsyncMock(return_value=session)
    cm.__aexit__ = AsyncMock(return_value=False)
    driver = MagicMock()
    driver.session.return_value = cm

    await bootstrap_neo4j(driver)

    executed = [c.args[0] for c in session.run.call_args_list]
    for stmt in _NEO4J_CONSTRAINTS:
        assert stmt in executed
