"""Merge a supply-chain network YAML overlay into Postgres + Neo4j.

Run after seed_demo.py (base demo). Same entity ids upsert; new ids add.

Usage:
    uv run seed-network-overlay data/supply-chain-network.yaml
    NETWORK_YAML=path/to/file.yaml uv run seed-network-overlay
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
from pathlib import Path

from lib.core.config import Settings
from lib.importers.network_yaml import compile_network_yaml, load_network_yaml
from lib.seed.writers import write_network_overlay

logging.basicConfig(level=logging.INFO, format="%(levelname)s — %(message)s")
logger = logging.getLogger(__name__)


def _resolve_yaml_path() -> Path:
    env_path = os.environ.get("NETWORK_YAML", "").strip()
    if env_path:
        return Path(env_path)
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    raise SystemExit(
        "Usage: seed-network-overlay <path-to-network.yaml>\n"
        "   or: NETWORK_YAML=path/to/file.yaml seed-network-overlay"
    )


async def main() -> None:
    settings = Settings()
    if not settings.neo4j_password:
        raise SystemExit(
            "NEO4J_PASSWORD is not set. For local seeding, copy .env.example to .env."
        )

    yaml_path = _resolve_yaml_path()
    logger.info("Loading network overlay from %s", yaml_path)
    raw = load_network_yaml(yaml_path)
    bundle = compile_network_yaml(raw)

    if bundle.issues:
        for issue in bundle.issues:
            logger.log(
                logging.ERROR if issue.level == "error" else logging.WARNING,
                "%s%s",
                issue.message,
                f" (row {issue.row})" if issue.row else "",
            )

    if not bundle.ok:
        raise SystemExit(
            f"Network overlay has {bundle.error_count} error(s); aborting commit."
        )

    logger.info(
        "Committing overlay: entities=%d carries=%d dependencies=%d scenarios=%d",
        len(bundle.entities),
        len(bundle.carries_edges),
        len(bundle.dependency_edges),
        len(bundle.scenarios),
    )
    await write_network_overlay(settings, bundle)
    logger.info("Network overlay seed complete.")


if __name__ == "__main__":
    asyncio.run(main())
