"""CLI entry point for demo seed data (UK airspace closure + related scenarios).

Runs ``scripts/seed_demo.py`` so the same logic is available locally
(``uv run seed-demo``) and in-cluster (``oc exec … -- seed-demo``).
"""
from __future__ import annotations

import runpy
import sys
from pathlib import Path


def _seed_script_path() -> Path:
    # Installed image: /app/scripts/seed_demo.py
    # Local dev:       <repo>/scripts/seed_demo.py
    root = Path(__file__).resolve().parents[2]
    path = root / "scripts" / "seed_demo.py"
    if not path.is_file():
        raise SystemExit(f"seed script not found: {path}")
    return path


def main() -> None:
    path = _seed_script_path()
    root = path.parent.parent
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    runpy.run_path(str(path), run_name="__main__")


if __name__ == "__main__":
    main()
