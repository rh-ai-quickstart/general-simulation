"""Tests for supply-chain network YAML compilation."""
from __future__ import annotations

from pathlib import Path

import pytest

from lib.importers.network_yaml import compile_network_yaml, load_network_yaml

FIXTURE = (
    Path(__file__).resolve().parent / "fixtures" / "supply_chain_network.example.yaml"
)


def test_load_example_fixture() -> None:
    raw = load_network_yaml(FIXTURE)
    assert raw["version"] == "1"
    assert raw["dataset_id"] == "supply-chain-overlay-example"


def test_compile_example_counts() -> None:
    raw = load_network_yaml(FIXTURE)
    bundle = compile_network_yaml(raw)
    assert bundle.ok
    assert bundle.error_count == 0
    assert len(bundle.entities) == 4
    assert len(bundle.carries_edges) == 1
    assert len(bundle.dependency_edges) == 2  # explicit + SKU -> warehouse


def test_sku_value_usd_computed() -> None:
    raw = load_network_yaml(FIXTURE)
    bundle = compile_network_yaml(raw)
    sku = next(e for e in bundle.entities if e.id == "sku-overlay-pharma-01")
    assert sku.attributes["value_usd"] == 24 * 8500.0
    assert sku.attributes["quantity"] == 24


def test_company_id_from_file_default() -> None:
    raw = {
        "version": "1",
        "company_id": "company-1",
        "company_name": "Acme Corp",
        "flights": [
            {
                "id": "flight-test",
                "callsign": "TST001",
                "route": "A-B",
                "lon": 1.0,
                "lat": 2.0,
            }
        ],
    }
    bundle = compile_network_yaml(raw)
    flight = next(e for e in bundle.entities if e.id == "flight-test")
    assert flight.attributes["company_id"] == "company-1"
    assert flight.attributes["company_name"] == "Acme Corp"


def test_cargo_sku_ref_links_carrier() -> None:
    raw = load_network_yaml(FIXTURE)
    bundle = compile_network_yaml(raw)
    sku = next(e for e in bundle.entities if e.id == "sku-overlay-pharma-01")
    assert "flight-baw177" in sku.attributes["linked_carrier_ids"]


def test_cargo_value_usd() -> None:
    raw = load_network_yaml(FIXTURE)
    bundle = compile_network_yaml(raw)
    cargo = next(e for e in bundle.entities if e.id == "cargo-flight-baw177-pharma")
    assert cargo.attributes["value_usd"] == 8 * 8500.0


def test_validation_catches_missing_cargo_sku_ref() -> None:
    raw = load_network_yaml(FIXTURE)
    raw = dict(raw)
    raw["cargo"] = [
        {
            "id": "cargo-bad",
            "carrier_id": "flight-baw177",
            "sku_ref": "sku-does-not-exist",
            "commodity": "test",
            "quantity": 1,
            "unit_price_usd": 10,
        }
    ]
    bundle = compile_network_yaml(raw)
    assert any(
        i.level == "error" and "sku-does-not-exist" in i.message
        for i in bundle.issues
    )
    assert not bundle.ok


def test_validation_warns_external_warehouse() -> None:
    raw = {
        "version": "1",
        "inventory_skus": [
            {
                "id": "sku-ext-wh",
                "sku": "EXT-1",
                "warehouse_id": "warehouse-inland-empire",
                "on_hand_qty": 5,
                "unit_price_usd": 100,
            }
        ],
    }
    bundle = compile_network_yaml(raw)
    assert bundle.ok
    assert any(
        i.level == "warning" and "warehouse-inland-empire" in i.message
        for i in bundle.issues
    )


def test_missing_version_raises(tmp_path: Path) -> None:
    bad_file = tmp_path / "bad.yaml"
    bad_file.write_text("dataset_id: x\nairports: []\n", encoding="utf-8")
    with pytest.raises(ValueError, match="Unsupported network YAML version"):
        load_network_yaml(bad_file)
