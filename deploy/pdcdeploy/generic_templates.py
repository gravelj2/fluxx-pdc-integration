"""Locate the Generic Template stencil that hosts oauth-callback.html.

"Generic Template" is not its own listable REST resource -- confirmed
against TRN on 2026-09-24: `GET /generic_template` reports `total_entries:
0`, and fetching by the ids a dashboard card references
(`/generic_templates/{id}` in `DashboardTemplate.data`) returns only `{"id":
N}` with every other field empty, no matter which `cols` are requested.

The resolution: `/generic_templates/{id}` in a dashboard card's `detail.url`
is actually a **Stencil id** where `Stencil.model_type == "GenericTemplate"`.
"Generic Template" is a stencil-naming convention, not a separate table.

The discovery chain (per the user, confirmed live against TRN):
    UserProfile (categories includes "grantee")
      -> dashboard_template_ids[0]
      -> DashboardTemplate.data (JSON) -> cards[0].detail.url
      -> that url's trailing id is a Stencil id (model_type GenericTemplate)

This id is NOT safe to hardcode: the user confirmed it will be foundation
-specific and different in every other Fluxx instance this is deployed to.
It must be re-derived per instance, every run.

Known gap this chain does not yet handle (see docs/roadmap.md): TRN has TWO
profiles with "grantee" in `categories` (`Grantee` id 77 and `Borrower` id
1779). This module reports all of them rather than silently picking one --
see `GranteeProfileTemplate.ambiguous`.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from .fluxx_client import FluxxClient

GRANTEE_CATEGORY = "grantee"
GENERIC_TEMPLATE_URL_RE = re.compile(r"/generic_templates/(\d+)")


@dataclass(frozen=True)
class GranteeProfileTemplate:
    profile_id: int
    profile_name: str
    dashboard_template_id: int | None
    first_card_title: str | None
    stencil_id: int | None
    stencil_name: str | None
    contains_oauth: bool


def find_grantee_generic_templates(client: FluxxClient) -> list[GranteeProfileTemplate]:
    """One result per UserProfile whose `categories` includes "grantee".

    Multiple results mean multiple candidate profiles exist (as they do on
    TRN) -- callers must not assume there's exactly one; report all and let
    a human pick, per the ambiguity this was designed to surface.
    """
    profiles = client.list_all(
        "user_profile", ["id", "name", "categories", "dashboard_template_ids"]
    )
    grantee_profiles = [
        p for p in profiles if GRANTEE_CATEGORY in json.loads(p["categories"] or "[]")
    ]

    results: list[GranteeProfileTemplate] = []
    for profile in grantee_profiles:
        template_ids = json.loads(profile["dashboard_template_ids"] or "[]")
        if not template_ids:
            results.append(
                GranteeProfileTemplate(
                    profile_id=profile["id"],
                    profile_name=profile["name"],
                    dashboard_template_id=None,
                    first_card_title=None,
                    stencil_id=None,
                    stencil_name=None,
                    contains_oauth=False,
                )
            )
            continue

        # dashboard_template_ids can hold ints or numeric strings (seen both
        # on TRN: "[12286]" and "[\"20398\"]") -- normalize before use.
        dashboard_template_id = int(template_ids[0])
        dashboard = client.fetch(
            "dashboard_template", dashboard_template_id, cols=["id", "name", "data"]
        )
        data_raw = dashboard.get("data")
        cards = json.loads(data_raw)["cards"] if data_raw else []

        first_card_title = None
        stencil_id = None
        for card in cards:
            url = (card.get("detail") or {}).get("url")
            if not url:
                continue
            match = GENERIC_TEMPLATE_URL_RE.search(url)
            if match:
                first_card_title = card.get("title")
                stencil_id = int(match.group(1))
                break

        stencil_name = None
        contains_oauth = False
        if stencil_id is not None:
            stencil = client.fetch("stencil", stencil_id, cols=["id", "name", "model_type", "json"])
            stencil_name = stencil.get("name")
            contains_oauth = "oauth" in (stencil.get("json") or "").lower()

        results.append(
            GranteeProfileTemplate(
                profile_id=profile["id"],
                profile_name=profile["name"],
                dashboard_template_id=dashboard_template_id,
                first_card_title=first_card_title,
                stencil_id=stencil_id,
                stencil_name=stencil_name,
                contains_oauth=contains_oauth,
            )
        )
    return results
