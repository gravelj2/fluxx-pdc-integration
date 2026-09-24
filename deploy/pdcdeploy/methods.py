"""Inventory of named Fluxx methods (`ModelMethod`) for the PDC integration.

`ModelMethod` covers both named methods and simple lifecycle hooks -- they're
distinguished by `method_type` (`method`, `before_save`, `after_save`), not by
living in separate tables. Confirmed against TRN on 2026-09-24: this is a
DIFFERENT mechanism from the `AfterEnter - Granted`-style hook described in
docs/architecture.md, which lives on `MachineState.unsafe_after_enter`
instead -- see hooks.py.
"""

from __future__ import annotations

from dataclasses import dataclass

from .fluxx_client import FluxxClient
from .manifest import TRACKED_MODEL_TYPES, is_grant_request_pdc_method

METHOD_LIST_COLS = ["id", "name", "model_type", "method_type"]


@dataclass(frozen=True)
class MethodRef:
    id: int
    name: str
    model_type: str
    method_type: str


def find_tracked_methods(client: FluxxClient) -> dict[str, list[MethodRef]]:
    """Return every method for the three tracked PDC dynamic models (all of
    them -- these models have no non-PDC methods), plus GrantRequest's
    methods filtered to the "PDC "-prefix naming convention (GrantRequest has
    ~100 methods total; only a handful belong to this integration).
    """
    all_methods = client.list_all("model_method", METHOD_LIST_COLS)

    by_model_type: dict[str, list[MethodRef]] = {}
    for record in all_methods:
        model_type = record["model_type"]
        ref = MethodRef(
            id=record["id"],
            name=record["name"],
            model_type=model_type,
            method_type=record["method_type"],
        )
        if model_type in TRACKED_MODEL_TYPES:
            by_model_type.setdefault(model_type, []).append(ref)
        elif model_type == "GrantRequest" and is_grant_request_pdc_method(ref.name):
            by_model_type.setdefault(model_type, []).append(ref)

    return by_model_type


def fetch_body(client: FluxxClient, method_id: int) -> str:
    """The Ruby source for one method. Field name confirmed against TRN."""
    record = client.fetch("model_method", method_id, cols=["unsafe_dyn_method"])
    return record.get("unsafe_dyn_method") or ""
