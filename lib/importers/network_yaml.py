"""Parse and compile domain-friendly supply-chain network YAML manifests."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

from lib.core.ingestion import CanonicalEntity
from lib.graph.nodes import EDGE_CARRIES, EDGE_DEPENDS_ON
from lib.importers.models import ImportIssue

_SUPPORTED_VERSIONS = frozenset({"1"})
_ENTITY_SECTIONS = (
    "airports",
    "ports",
    "warehouses",
    "flights",
    "vessels",
    "cargo",
    "inventory_skus",
)


@dataclass
class Neo4jEntityWrite:
    """Rich Entity node properties for Neo4j MERGE (mirrors seed_demo.py)."""

    id: str
    type: str
    props: dict[str, Any] = field(default_factory=dict)


@dataclass
class NetworkSeedBundle:
    entities: list[CanonicalEntity] = field(default_factory=list)
    neo4j_entities: list[Neo4jEntityWrite] = field(default_factory=list)
    carries_edges: list[tuple[str, str]] = field(default_factory=list)
    dependency_edges: list[tuple[str, str, str]] = field(default_factory=list)
    scenarios: list[dict[str, Any]] = field(default_factory=list)
    issues: list[ImportIssue] = field(default_factory=list)
    dataset_id: str | None = None

    @property
    def error_count(self) -> int:
        return sum(1 for i in self.issues if i.level == "error")

    @property
    def ok(self) -> bool:
        return self.error_count == 0 and bool(
            self.entities or self.dependency_edges or self.scenarios
        )


def load_network_yaml(path: Path | str) -> dict[str, Any]:
    """Load and return parsed YAML; raises on missing file or invalid YAML."""
    file_path = Path(path)
    if not file_path.is_file():
        raise FileNotFoundError(f"Network YAML not found: {file_path}")
    raw = yaml.safe_load(file_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError("Network YAML root must be a mapping")
    version = str(raw.get("version", "")).strip()
    if version not in _SUPPORTED_VERSIONS:
        raise ValueError(
            f"Unsupported network YAML version {version!r}; "
            f"expected one of {sorted(_SUPPORTED_VERSIONS)}"
        )
    return raw


def compile_network_yaml(raw: dict[str, Any]) -> NetworkSeedBundle:
    """Compile a parsed network manifest into entities and graph edges."""
    bundle = NetworkSeedBundle(dataset_id=raw.get("dataset_id"))
    default_company_id = raw.get("company_id")
    default_company_name = raw.get("company_name")
    now = datetime.now(timezone.utc)
    entity_ids: set[str] = set()
    carrier_ids: set[str] = set()
    warehouse_ids: set[str] = set()
    sku_by_id: dict[str, dict[str, Any]] = {}

    for section in _ENTITY_SECTIONS:
        rows = raw.get(section) or []
        if not isinstance(rows, list):
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=f"Section {section!r} must be a list",
                )
            )
            continue
        for index, row in enumerate(rows, start=1):
            if not isinstance(row, dict):
                bundle.issues.append(
                    ImportIssue(
                        level="error",
                        message=f"{section}[{index}] must be an object",
                        row=index,
                    )
                )
                continue
            _compile_row(
                section=section,
                row=row,
                row_num=index,
                now=now,
                bundle=bundle,
                entity_ids=entity_ids,
                carrier_ids=carrier_ids,
                warehouse_ids=warehouse_ids,
                sku_by_id=sku_by_id,
                dataset_id=bundle.dataset_id,
                default_company_id=default_company_id,
                default_company_name=default_company_name,
            )

    _apply_cargo_sku_links(raw.get("cargo") or [], sku_by_id, bundle)
    _compile_dependencies(raw.get("dependencies") or [], bundle, entity_ids)
    _compile_scenarios(raw.get("scenarios") or [], bundle)
    validate_network_bundle(bundle)
    return bundle


def validate_network_bundle(bundle: NetworkSeedBundle) -> NetworkSeedBundle:
    """Append referential integrity issues to the bundle.

    Overlay imports may reference entities from a prior base seed; those
    produce warnings rather than errors.
    """
    entity_ids = {e.id for e in bundle.entities}
    for index, (from_id, to_id, edge_type) in enumerate(
        bundle.dependency_edges, start=1
    ):
        if from_id not in entity_ids:
            bundle.issues.append(
                ImportIssue(
                    level="warning",
                    message=(
                        f"dependency from_id {from_id!r} not in this import "
                        f"(edge_type={edge_type}; may exist from base seed)"
                    ),
                    row=index,
                )
            )
        if to_id not in entity_ids:
            bundle.issues.append(
                ImportIssue(
                    level="warning",
                    message=(
                        f"dependency to_id {to_id!r} not in this import "
                        f"(edge_type={edge_type}; may exist from base seed)"
                    ),
                    row=index,
                )
            )

    for index, (carrier_id, cargo_id) in enumerate(bundle.carries_edges, start=1):
        if carrier_id not in entity_ids:
            bundle.issues.append(
                ImportIssue(
                    level="warning",
                    message=(
                        f"cargo carrier_id {carrier_id!r} not in this import "
                        "(may exist from base seed)"
                    ),
                    row=index,
                )
            )
        if cargo_id not in entity_ids:
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=f"cargo id {cargo_id!r} not found in this import",
                    row=index,
                )
            )

    for entity in bundle.entities:
        if entity.type == "inventory_sku":
            warehouse_id = entity.attributes.get("warehouse_id")
            if warehouse_id and warehouse_id not in entity_ids:
                bundle.issues.append(
                    ImportIssue(
                        level="warning",
                        message=(
                            f"SKU {entity.id!r} references warehouse_id "
                            f"{warehouse_id!r} not in this import "
                            "(may exist from base seed)"
                        ),
                    )
                )
            for carrier_id in entity.attributes.get("linked_carrier_ids") or []:
                if carrier_id not in entity_ids:
                    bundle.issues.append(
                        ImportIssue(
                            level="warning",
                            message=(
                                f"SKU {entity.id!r} linked_carrier_ids "
                                f"references {carrier_id!r} not in this import "
                                "(may exist from base seed)"
                            ),
                        )
                    )

    return bundle


def _compile_row(
    *,
    section: str,
    row: dict[str, Any],
    row_num: int,
    now: datetime,
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
    carrier_ids: set[str],
    warehouse_ids: set[str],
    sku_by_id: dict[str, dict[str, Any]],
    dataset_id: str | None,
    default_company_id: Any = None,
    default_company_name: Any = None,
) -> None:
    entity_id = _require_str(row, "id", section, row_num, bundle)
    if not entity_id:
        return
    if entity_id in entity_ids:
        bundle.issues.append(
            ImportIssue(
                level="error",
                message=f"Duplicate entity id {entity_id!r}",
                row=row_num,
            )
        )
        return

    if section in {"airports", "ports", "warehouses"}:
        _compile_facility(
            section, row, entity_id, now, bundle, entity_ids, dataset_id
        )
        if section == "warehouses":
            warehouse_ids.add(entity_id)
        return

    if section == "flights":
        _compile_flight(
            row,
            entity_id,
            now,
            bundle,
            entity_ids,
            carrier_ids,
            dataset_id,
            default_company_id=default_company_id,
            default_company_name=default_company_name,
        )
        return

    if section == "vessels":
        _compile_vessel(row, entity_id, now, bundle, entity_ids, carrier_ids, dataset_id)
        return

    if section == "cargo":
        _compile_cargo(row, entity_id, now, bundle, entity_ids, dataset_id)
        return

    if section == "inventory_skus":
        _compile_sku(
            row,
            entity_id,
            now,
            bundle,
            entity_ids,
            sku_by_id,
            warehouse_ids,
            dataset_id,
        )


def _compile_facility(
    section: str,
    row: dict[str, Any],
    entity_id: str,
    now: datetime,
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
    dataset_id: str | None,
) -> None:
    name = _require_str(row, "name", section, 0, bundle)
    lon = _require_float(row, "lon", section, 0, bundle)
    lat = _require_float(row, "lat", section, 0, bundle)
    if not name or lon is None or lat is None:
        return

    facility_kind = {
        "airports": "airport",
        "ports": "port",
        "warehouses": "warehouse",
    }[section]

    attrs: dict[str, Any] = {
        "name": name,
        "facility_kind": facility_kind,
        "source": "network_yaml",
    }
    if dataset_id:
        attrs["dataset_id"] = dataset_id
    for key in (
        "region",
        "iata",
        "icao",
        "value_usd",
        "throughput_teu_day",
        "country",
    ):
        if key in row and row[key] is not None:
            attrs[key] = row[key]

    entity = CanonicalEntity(
        id=entity_id,
        type="facility",
        timestamp=now,
        status=str(row.get("status") or "operational"),
        geometry={"type": "Point", "coordinates": [lon, lat]},
        attributes=attrs,
    )
    neo4j_props = {
        "name": name,
        "facility_kind": facility_kind,
        "region": attrs.get("region"),
        "value_usd": attrs.get("value_usd"),
    }
    bundle.entities.append(entity)
    bundle.neo4j_entities.append(
        Neo4jEntityWrite(id=entity_id, type="facility", props=neo4j_props)
    )
    entity_ids.add(entity_id)


def _compile_flight(
    row: dict[str, Any],
    entity_id: str,
    now: datetime,
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
    carrier_ids: set[str],
    dataset_id: str | None,
    *,
    default_company_id: Any = None,
    default_company_name: Any = None,
) -> None:
    callsign = _require_str(row, "callsign", "flights", 0, bundle)
    route = _require_str(row, "route", "flights", 0, bundle)
    lon = _require_float(row, "lon", "flights", 0, bundle)
    lat = _require_float(row, "lat", "flights", 0, bundle)
    if not callsign or not route or lon is None or lat is None:
        return

    attrs: dict[str, Any] = {
        "call_sign": callsign,
        "route": route,
        "source": "network_yaml",
    }
    if dataset_id:
        attrs["dataset_id"] = dataset_id
    for key in (
        "origin",
        "origin_country",
        "revenue_usd",
        "operating_cost_usd",
        "depends_on_port",
        "promised_delivery_utc",
        "eta_utc",
    ):
        if key in row and row[key] is not None:
            mapped = "origin_country" if key == "origin" else key
            attrs[mapped] = row[key]

    company_id = row.get("company_id") or default_company_id
    company_name = row.get("company_name") or default_company_name
    if company_id not in (None, ""):
        attrs["company_id"] = str(company_id)
    if company_name not in (None, ""):
        attrs["company_name"] = str(company_name)

    entity = CanonicalEntity(
        id=entity_id,
        type="moving_entity",
        timestamp=now,
        status=str(row.get("status") or "airborne"),
        geometry={"type": "Point", "coordinates": [lon, lat]},
        attributes=attrs,
    )
    neo4j_props = {
        "callsign": callsign,
        "origin": attrs.get("origin_country") or attrs.get("origin"),
        "route": route,
        "revenue_usd": attrs.get("revenue_usd"),
        "depends_on_port": attrs.get("depends_on_port"),
        "company_id": attrs.get("company_id"),
        "company_name": attrs.get("company_name"),
    }
    bundle.entities.append(entity)
    bundle.neo4j_entities.append(
        Neo4jEntityWrite(id=entity_id, type="moving_entity", props=neo4j_props)
    )
    entity_ids.add(entity_id)
    carrier_ids.add(entity_id)


def _compile_vessel(
    row: dict[str, Any],
    entity_id: str,
    now: datetime,
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
    carrier_ids: set[str],
    dataset_id: str | None,
) -> None:
    name = _require_str(row, "name", "vessels", 0, bundle)
    route = _require_str(row, "route", "vessels", 0, bundle)
    lon = _require_float(row, "lon", "vessels", 0, bundle)
    lat = _require_float(row, "lat", "vessels", 0, bundle)
    if not name or not route or lon is None or lat is None:
        return

    attrs: dict[str, Any] = {
        "name": name,
        "route": route,
        "source": "network_yaml",
    }
    if dataset_id:
        attrs["dataset_id"] = dataset_id
    for key in (
        "revenue_usd",
        "depends_on_port",
        "promised_delivery_utc",
        "eta_utc",
    ):
        if key in row and row[key] is not None:
            attrs[key] = row[key]

    entity = CanonicalEntity(
        id=entity_id,
        type="moving_entity",
        timestamp=now,
        status=str(row.get("status") or "in_transit"),
        geometry={"type": "Point", "coordinates": [lon, lat]},
        attributes=attrs,
    )
    neo4j_props = {
        "name": name,
        "route": route,
        "revenue_usd": attrs.get("revenue_usd"),
        "depends_on_port": attrs.get("depends_on_port"),
    }
    bundle.entities.append(entity)
    bundle.neo4j_entities.append(
        Neo4jEntityWrite(id=entity_id, type="moving_entity", props=neo4j_props)
    )
    entity_ids.add(entity_id)
    carrier_ids.add(entity_id)


def _compile_cargo(
    row: dict[str, Any],
    entity_id: str,
    now: datetime,
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
    dataset_id: str | None,
) -> None:
    carrier_id = _require_str(row, "carrier_id", "cargo", 0, bundle)
    commodity = _require_str(row, "commodity", "cargo", 0, bundle)
    quantity = _require_float(row, "quantity", "cargo", 0, bundle)
    unit_price = _require_float(row, "unit_price_usd", "cargo", 0, bundle)
    if not carrier_id or not commodity or quantity is None or unit_price is None:
        return

    value_usd = float(quantity) * float(unit_price)
    attrs: dict[str, Any] = {
        "commodity": commodity,
        "quantity": quantity,
        "unit_price_usd": unit_price,
        "value_usd": value_usd,
        "carrier_id": carrier_id,
        "source": "network_yaml",
    }
    if dataset_id:
        attrs["dataset_id"] = dataset_id
    if row.get("sku_ref"):
        attrs["sku_ref"] = row["sku_ref"]

    entity = CanonicalEntity(
        id=entity_id,
        type="cargo_item",
        timestamp=now,
        status=str(row.get("status") or "in_transit"),
        geometry=None,
        attributes=attrs,
    )
    neo4j_props = {
        "commodity": commodity,
        "quantity": quantity,
        "unit_price_usd": unit_price,
        "value_usd": value_usd,
        "carrier_id": carrier_id,
    }
    bundle.entities.append(entity)
    bundle.neo4j_entities.append(
        Neo4jEntityWrite(id=entity_id, type="cargo_item", props=neo4j_props)
    )
    bundle.carries_edges.append((carrier_id, entity_id))
    entity_ids.add(entity_id)


def _compile_sku(
    row: dict[str, Any],
    entity_id: str,
    now: datetime,
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
    sku_by_id: dict[str, dict[str, Any]],
    warehouse_ids: set[str],
    dataset_id: str | None,
) -> None:
    sku = _require_str(row, "sku", "inventory_skus", 0, bundle)
    warehouse_id = _require_str(row, "warehouse_id", "inventory_skus", 0, bundle)
    on_hand_qty = _require_float(row, "on_hand_qty", "inventory_skus", 0, bundle)
    unit_price = _require_float(row, "unit_price_usd", "inventory_skus", 0, bundle)
    if not sku or not warehouse_id or on_hand_qty is None or unit_price is None:
        return

    linked = list(row.get("linked_carrier_ids") or [])
    value_usd = float(on_hand_qty) * float(unit_price)
    attrs: dict[str, Any] = {
        "sku": sku,
        "warehouse_id": warehouse_id,
        "on_hand_qty": on_hand_qty,
        "quantity": on_hand_qty,
        "unit_price_usd": unit_price,
        "value_usd": value_usd,
        "linked_carrier_ids": linked,
        "source": "network_yaml",
    }
    if dataset_id:
        attrs["dataset_id"] = dataset_id
    for key in (
        "commodity",
        "safety_stock",
        "reorder_point",
        "avg_daily_sales_30d",
    ):
        if key in row and row[key] is not None:
            attrs[key] = row[key]

    entity = CanonicalEntity(
        id=entity_id,
        type="inventory_sku",
        timestamp=now,
        status=str(row.get("status") or "in_stock"),
        geometry=None,
        attributes=attrs,
    )
    neo4j_props = {
        "sku": sku,
        "commodity": attrs.get("commodity"),
        "warehouse_id": warehouse_id,
        "on_hand_qty": on_hand_qty,
        "safety_stock": attrs.get("safety_stock"),
        "reorder_point": attrs.get("reorder_point"),
        "unit_price_usd": unit_price,
        "avg_daily_sales_30d": attrs.get("avg_daily_sales_30d"),
    }
    bundle.entities.append(entity)
    bundle.neo4j_entities.append(
        Neo4jEntityWrite(id=entity_id, type="inventory_sku", props=neo4j_props)
    )
    bundle.dependency_edges.append((entity_id, warehouse_id, EDGE_DEPENDS_ON))
    entity_ids.add(entity_id)
    warehouse_ids.add(warehouse_id)
    sku_by_id[entity_id] = row


def _apply_cargo_sku_links(
    cargo_rows: list[Any],
    sku_by_id: dict[str, dict[str, Any]],
    bundle: NetworkSeedBundle,
) -> None:
    """Auto-link cargo sku_ref to linked_carrier_ids on matching SKUs."""
    if not isinstance(cargo_rows, list):
        return
    for row in cargo_rows:
        if not isinstance(row, dict):
            continue
        sku_ref = row.get("sku_ref")
        carrier_id = row.get("carrier_id")
        if not sku_ref or not carrier_id:
            continue
        for entity in bundle.entities:
            if entity.id != sku_ref or entity.type != "inventory_sku":
                continue
            linked = list(entity.attributes.get("linked_carrier_ids") or [])
            if carrier_id not in linked:
                linked.append(carrier_id)
                entity.attributes["linked_carrier_ids"] = linked
            break
        else:
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=(
                        f"cargo sku_ref {sku_ref!r} does not match "
                        "any inventory_skus id in this import"
                    ),
                )
            )


def _compile_dependencies(
    rows: list[Any],
    bundle: NetworkSeedBundle,
    entity_ids: set[str],
) -> None:
    if not isinstance(rows, list):
        bundle.issues.append(
            ImportIssue(level="error", message="dependencies must be a list")
        )
        return
    for index, row in enumerate(rows, start=1):
        if not isinstance(row, dict):
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=f"dependencies[{index}] must be an object",
                    row=index,
                )
            )
            continue
        from_id = row.get("from") or row.get("from_id")
        to_id = row.get("to") or row.get("to_id")
        if not from_id or not to_id:
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=f"dependencies[{index}] requires from and to",
                    row=index,
                )
            )
            continue
        edge_type = str(row.get("edge_type") or EDGE_DEPENDS_ON).strip().upper()
        bundle.dependency_edges.append((str(from_id), str(to_id), edge_type))


def _compile_scenarios(rows: list[Any], bundle: NetworkSeedBundle) -> None:
    if not isinstance(rows, list):
        bundle.issues.append(
            ImportIssue(level="error", message="scenarios must be a list")
        )
        return
    for index, row in enumerate(rows, start=1):
        if not isinstance(row, dict):
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=f"scenarios[{index}] must be an object",
                    row=index,
                )
            )
            continue
        scenario_id = row.get("scenario_id")
        event_id = row.get("event_id")
        bbox = row.get("bbox")
        description = row.get("description")
        if not scenario_id or not event_id or not bbox or not description:
            bundle.issues.append(
                ImportIssue(
                    level="error",
                    message=(
                        f"scenarios[{index}] requires scenario_id, event_id, "
                        "bbox, description"
                    ),
                    row=index,
                )
            )
            continue
        bundle.scenarios.append(
            {
                "scenario_id": str(scenario_id),
                "event_id": str(event_id),
                "bbox": str(bbox),
                "description": str(description),
            }
        )


def _require_str(
    row: dict[str, Any],
    key: str,
    section: str,
    row_num: int,
    bundle: NetworkSeedBundle,
) -> str | None:
    value = row.get(key)
    if value is None or str(value).strip() == "":
        bundle.issues.append(
            ImportIssue(
                level="error",
                message=f"{section} missing required field {key!r}",
                row=row_num or None,
            )
        )
        return None
    return str(value).strip()


def _require_float(
    row: dict[str, Any],
    key: str,
    section: str,
    row_num: int,
    bundle: NetworkSeedBundle,
) -> float | None:
    value = row.get(key)
    if value is None or str(value).strip() == "":
        bundle.issues.append(
            ImportIssue(
                level="error",
                message=f"{section} missing required field {key!r}",
                row=row_num or None,
            )
        )
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        bundle.issues.append(
            ImportIssue(
                level="error",
                message=f"{section}.{key} must be numeric",
                row=row_num or None,
            )
        )
        return None
