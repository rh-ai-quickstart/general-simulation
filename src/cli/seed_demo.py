"""CLI entry point for demo seed data (UK airspace closure + related scenarios).

Runs ``scripts/seed_demo.py`` so the same logic is available locally
(``uv run seed-demo``) and in-cluster (``oc exec … -- seed-demo``).
"""
from __future__ import annotations

import runpy
import sys
from pathlib import Path


def _seed_script_path() -> Path:
    # Container image: /app/scripts/seed_demo.py (see deploy/app/Containerfile)
    # Local dev:       <repo>/scripts/seed_demo.py
    candidates = [
        Path("/app/scripts/seed_demo.py"),
    ]
    for parent in Path(__file__).resolve().parents:
        candidates.append(parent / "scripts" / "seed_demo.py")
    for path in candidates:
        if path.is_file():
            return path
    raise SystemExit("seed script not found: scripts/seed_demo.py")


def main() -> None:
    path = _seed_script_path()
    root = path.parent.parent
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    runpy.run_path(str(path), run_name="__main__")


if __name__ == "__main__":
    main()
