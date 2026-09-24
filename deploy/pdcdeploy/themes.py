"""Which GrantRequest theme(s) currently have PDC work installed.

A model type can have multiple `ModelTheme`s, each with its own
`MachineWorkflow`. Confirmed on TRN (2026-09-24): a `MachineState` is a
single shared row with ONE `unsafe_after_enter` body -- there is no
per-theme override. State 10 ("granted") is reached by 4 of GrantRequest's 5
themes' workflows (Grant Request, Grant Request - Fellows, X-Grants, General
Operations; only Impact Investments doesn't reach it), all running the exact
same hook body. See docs/roadmap.md "Theme selection" for why this matters
for future writes: a write to a shared state affects every theme that
reaches it, not just the one a user thinks they're targeting.

This module only reports what's *already there*; it doesn't select a target
for writes (that's future work). "Theme has PDC installed" is defined as "at
least one of this theme's workflow's events targets a PDC-hooked state" --
deliberately not "this theme owns a PDC-hooked state", since state ownership
isn't 1:1 with theme.
"""

from __future__ import annotations

from dataclasses import dataclass

from .fluxx_client import FluxxClient
from .hooks import HookRef

THEME_LIST_COLS = ["id", "name", "model_type"]
WORKFLOW_LIST_COLS = ["id", "name", "model_type", "model_theme_id"]
EVENT_LIST_COLS = ["id", "machine_workflow_id", "to_state_id", "button_name"]


@dataclass(frozen=True)
class ThemePdcStatus:
    theme_id: int
    theme_name: str
    workflow_id: int
    workflow_name: str
    has_pdc_hook: bool
    reachable_pdc_state_names: tuple[str, ...]


def find_theme_pdc_status(client: FluxxClient, model_type: str, pdc_hooks: list[HookRef]) -> list[ThemePdcStatus]:
    """For every theme of `model_type`, report whether its workflow reaches
    a state known to carry a PDC hook (from `pdc_hooks`, e.g. hooks.py's
    output).
    """
    pdc_state_ids = {h.state_id: h.state_name for h in pdc_hooks}

    all_themes = client.list_all("model_theme", THEME_LIST_COLS)
    themes = {t["id"]: t for t in all_themes if t["model_type"] == model_type}

    all_workflows = client.list_all("machine_workflow", WORKFLOW_LIST_COLS)
    workflows_by_theme = {
        w["model_theme_id"]: w for w in all_workflows if w["model_theme_id"] in themes
    }

    all_events = client.list_all("machine_event", EVENT_LIST_COLS)
    events_by_workflow: dict[int, list[dict]] = {}
    for event in all_events:
        events_by_workflow.setdefault(event["machine_workflow_id"], []).append(event)

    results: list[ThemePdcStatus] = []
    for theme_id, theme in themes.items():
        workflow = workflows_by_theme.get(theme_id)
        if workflow is None:
            continue
        events = events_by_workflow.get(workflow["id"], [])
        reachable = {
            pdc_state_ids[e["to_state_id"]] for e in events if e["to_state_id"] in pdc_state_ids
        }
        results.append(
            ThemePdcStatus(
                theme_id=theme_id,
                theme_name=theme["name"],
                workflow_id=workflow["id"],
                workflow_name=workflow["name"],
                has_pdc_hook=bool(reachable),
                reachable_pdc_state_names=tuple(sorted(reachable)),
            )
        )
    return results
