"""Shared pytest fixtures and helpers."""
from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock, MagicMock


def neo4j_run_result(
    *,
    data: list[dict[str, Any]] | None = None,
    single: dict[str, Any] | None = None,
) -> AsyncMock:
    result = AsyncMock()
    result.data = AsyncMock(return_value=data or [])
    record = None
    if single is not None:
        record = MagicMock()
        record.__getitem__ = lambda _self, key: single[key]
    result.single = AsyncMock(return_value=record)
    summary = MagicMock()
    summary.counters.relationships_deleted = 0
    result.consume = AsyncMock(return_value=summary)
    return result


def neo4j_driver_mock() -> tuple[MagicMock, AsyncMock]:
    """Return (driver, session) with a working async session context manager."""
    session = AsyncMock()
    session_cm = MagicMock()
    session_cm.__aenter__ = AsyncMock(return_value=session)
    session_cm.__aexit__ = AsyncMock(return_value=False)

    driver = MagicMock()
    driver.session = MagicMock(return_value=session_cm)
    return driver, session
