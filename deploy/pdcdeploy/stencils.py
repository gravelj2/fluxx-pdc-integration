"""Look up the Fluxx `Stencil` record for each tracked dynamic model type.

A `Stencil` holds a model's form/list/show layout as a JSON element tree
(labels, grouping, field order) -- it does NOT carry Ruby method bodies or
lifecycle-hook code; those live on `ModelMethod.unsafe_dyn_method` and
`ModelTheme.unsafe_before_new_block` / `unsafe_after_create_block`
respectively. See docs/architecture.md and the pdc-data-explorer-architecture
memory for how this fits into the wider integration.

Confirmed against TRN (macfound-trn.fluxx.io) on 2026-09-04:
    PDC Integration Map  (MacModelTypeDynPdcApplicationForm1) -> stencil 42071
    PDC Mapped Field     (MacModelTypeDynPdcMappedField1)     -> stencil 42073
    PDC Consent          (MacModelTypeDynPdcConsent)          -> stencil 45111
Each also has a second "Filter" stencil (form_type=["filter"]); this module
only returns the form/list/show one, since that's what deployment.md tracks.
"""

from __future__ import annotations

from dataclasses import dataclass

from .fluxx_client import FluxxClient
from .manifest import TRACKED_MODEL_TYPES

STENCIL_LIST_COLS = [
    "id",
    "name",
    "model_type",
    "form_type",
    "enabled",
    "has_custom_ruby_code",
    "model_theme_id",
    "updated_at",
]


@dataclass(frozen=True)
class StencilRef:
    model_type: str
    label: str
    stencil_id: int
    model_theme_id: int
    updated_at: str


def choose_primary_stencil(candidates: list[dict]) -> dict | None:
    """Among stencils sharing a model_type (or, for a multi-theme model
    type, a model_theme_id), pick the form/list/show one -- each also has a
    separate "Filter" stencil (form_type=["filter"]) that deployment.md
    doesn't track. Ties (more than one form/list/show stencil, seen for a
    handful of legacy GrantRequest themes on TRN) break by most-recently-
    updated, since that's the one likeliest to be the live layout.
    """
    primary = [c for c in candidates if "form" in (c.get("form_type") or "")]
    if not primary:
        return None
    if len(primary) > 1:
        primary.sort(key=lambda c: c["updated_at"], reverse=True)
    return primary[0]


def find_tracked_stencils(client: FluxxClient) -> dict[str, StencilRef]:
    """Return the primary (form/list/show) stencil for each tracked model type.

    Fetches every stencil once and filters client-side -- see
    fluxx_client.py's module docstring for why (server-side `filter` is
    silently ignored on this instance).
    """
    all_stencils = client.list_all("stencil", STENCIL_LIST_COLS)

    by_model_type: dict[str, list[dict]] = {}
    for record in all_stencils:
        by_model_type.setdefault(record["model_type"], []).append(record)

    result: dict[str, StencilRef] = {}
    for model_type, label in TRACKED_MODEL_TYPES.items():
        chosen = choose_primary_stencil(by_model_type.get(model_type, []))
        if chosen is None:
            continue
        result[model_type] = StencilRef(
            model_type=model_type,
            label=label,
            stencil_id=chosen["id"],
            model_theme_id=chosen["model_theme_id"],
            updated_at=chosen["updated_at"],
        )
    return result


def report_missing(found: dict[str, StencilRef]) -> list[str]:
    """Model types we expected to find a stencil for but didn't."""
    return [label for model_type, label in TRACKED_MODEL_TYPES.items() if model_type not in found]
