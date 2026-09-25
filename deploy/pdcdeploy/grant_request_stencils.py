"""Locate the GrantRequest form stencil(s) that hold the Data Explorer blocks.

Unlike the GenericTemplate case (one stencil, flat element list), GrantRequest
has one stencil per theme (51 on TRN) and the PDC blocks only live in the
stencils of themes that actually have PDC installed (per themes.py). Within
one of those stencils, the 7 PDC-owned elements (the 6 Data Explorer blocks
from docs/deployment.md, plus the read-only stencil-container variant --
confirmed on TRN, 2026-09-25, both interactive and read-only variants are
deployed side by side) sit nested one level inside a "Contribute to the
Philanthropy Data Commons (PDC)" `group` element, alongside unrelated form
fields (other programs' attributes) that must never be read, reported, or
touched.

The discovery chain:
    themes.find_theme_pdc_status(client, "GrantRequest", hooks)
      -> theme_id for every theme with has_pdc_hook=True
      -> stencil.choose_primary_stencil() among that theme's stencils
      -> compare.find_stencil_element_text() locates each of the 7 elements
         by its <!-- PDC:ELEMENT id=... --> marker, recursing into groups
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from .compare import find_stencil_element_text
from .fluxx_client import FluxxClient
from .stencils import STENCIL_LIST_COLS, choose_primary_stencil
from .themes import ThemePdcStatus

# element_id (from the PDC:ELEMENT marker) -> repo-relative path.
# Order matches the numeric load order in docs/deployment.md.
DATA_EXPLORER_ELEMENT_PATHS: dict[str, str] = {
    "portal-style": "data-explorer/1. portal-style.html",
    "fluxx-card-api": "data-explorer/2. fluxxCardAPI.html",
    "oauth-client": "data-explorer/3. oauth.html",
    "stencil-container": "data-explorer/4. pdc-stencil-container.html",
    "stencil-container-readonly": "data-explorer/4r. pdc-stencil-readonly.html",
    "floating-panel": "data-explorer/5. floating-panel.html",
}


@dataclass(frozen=True)
class GrantRequestStencilRef:
    theme_id: int
    theme_name: str
    stencil_id: int | None
    updated_at: str | None


def find_grant_request_pdc_stencils(
    client: FluxxClient, theme_statuses: list[ThemePdcStatus]
) -> list[GrantRequestStencilRef]:
    """One result per GrantRequest theme that has PDC installed (per
    themes.py), with that theme's primary form/list/show stencil id -- or
    None if that theme has no such stencil (surfaced, not silently skipped).
    """
    pdc_themes = [t for t in theme_statuses if t.has_pdc_hook]
    if not pdc_themes:
        return []

    all_stencils = client.list_all("stencil", STENCIL_LIST_COLS)
    by_theme: dict[int, list[dict]] = {}
    for record in all_stencils:
        # "Filter" stencils (form_type=["filter"]) come back with no
        # model_theme_id at all -- Fluxx silently omits inapplicable
        # columns rather than returning null (see fluxx_client.py) -- so a
        # plain record["model_theme_id"] raises KeyError on them.
        theme_id = record.get("model_theme_id")
        if record["model_type"] == "GrantRequest" and theme_id is not None:
            by_theme.setdefault(theme_id, []).append(record)

    results: list[GrantRequestStencilRef] = []
    for theme in pdc_themes:
        chosen = choose_primary_stencil(by_theme.get(theme.theme_id, []))
        results.append(
            GrantRequestStencilRef(
                theme_id=theme.theme_id,
                theme_name=theme.theme_name,
                stencil_id=chosen["id"] if chosen else None,
                updated_at=chosen["updated_at"] if chosen else None,
            )
        )
    return results


def fetch_element_raw_text(client: FluxxClient, stencil_id: int, element_id: str) -> str | None:
    """Raw (still HTML-entity-encoded) `config.text` for one marked element
    inside a GrantRequest stencil, or None if that stencil doesn't have it.
    """
    stencil = client.fetch("stencil", stencil_id, cols=["id", "json"])
    elements = json.loads(stencil.get("json") or "{}").get("elements", [])
    return find_stencil_element_text(elements, element_id)
