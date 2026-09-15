"""FastAPI application factory with lifespan resource management."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI

from apps.api.health import router as health_router
from apps.api.query import router as query_router
from apps.api.admin import router as admin_router

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Initialise shared resources on startup; clean up on shutdown.

    Blocks until Postgres and Neo4j accept connections so the process never
    serves traffic with ``app.state.pool is None`` (common race on cold
    OpenShift installs when the API pod starts before its databases).
    """
    from lib.core.config import Settings
    from lib.core.db import wait_for_neo4j, wait_for_pool
    from lib.ingestion.registry import resolve_solver
    from lib.llm.factory import get_llm_client

    settings = Settings()

    pool = await wait_for_pool(settings)
    neo4j_driver = await wait_for_neo4j(settings)

    app.state.pool = pool
    app.state.neo4j_driver = neo4j_driver
    app.state.llm_client = get_llm_client(settings, pool)
    app.state.solver = resolve_solver(settings)

    yield

    await pool.close()
    logger.info("Postgres pool closed")
    await neo4j_driver.close()
    logger.info("Neo4j driver closed")


app = FastAPI(
    title="General Simulation & Impact-Reasoning Platform",
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(health_router)
app.include_router(query_router)
app.include_router(admin_router)
