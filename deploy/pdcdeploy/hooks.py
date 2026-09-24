"""Inventory of GrantRequest lifecycle hooks that carry PDC logic.

Confirmed against TRN on 2026-09-24: the `AfterEnter - Granted` hook
docs/architecture.md describes lives on `MachineState.unsafe_after_enter`,
not on `ModelTheme` (whose before_new/after_create fields, checked across all
5 GrantRequest themes, hold only unrelated form-default-value scaffolding).

This module reports which states carry the hook. A state's `unsafe_after_enter`
is ONE shared body -- confirmed on TRN (2026-09-24) there is no per-theme
override mechanism, so "which theme(s) have this hook" really means "which
themes' workflows reach this exact state" (see themes.py and docs/roadmap.md
"Theme selection").
"""

from __future__ import annotations

from dataclasses import dataclass

from .fluxx_client import FluxxClient

STATE_LIST_COLS = ["id", "name", "model_type"]

# Presence of this marker is a precise signal (unlike a bare "pdc" substring,
# which false-positived on an unrelated comment mentioning "retired PDC's or
# Candid codes" during discovery). Falls back to a dyn_invoke_for scan since
# the marker itself isn't guaranteed to be there.
PDC_CODE_MARKER = "PDC_CODE"
PDC_INVOKE_HINT = 'dyn_invoke_for(:"PDC'


@dataclass(frozen=True)
class HookRef:
    state_id: int
    state_name: str
    model_type: str
    after_enter: str
    before_validation_enter: str


def _mentions_pdc(text: str) -> bool:
    return PDC_CODE_MARKER in text or PDC_INVOKE_HINT in text


def find_grant_request_pdc_hooks(client: FluxxClient) -> list[HookRef]:
    """Every GrantRequest MachineState whose after_enter / before_validation_enter
    actually invokes PDC logic (precise marker match, not a name/comment
    substring -- see module docstring).
    """
    all_states = client.list_all("machine_state", STATE_LIST_COLS)
    gr_states = [s for s in all_states if s["model_type"] == "GrantRequest"]

    hooks: list[HookRef] = []
    for state in gr_states:
        full = client.fetch(
            "machine_state",
            state["id"],
            cols=["unsafe_after_enter", "unsafe_before_validation_enter"],
        )
        after_enter = full.get("unsafe_after_enter") or ""
        before_validation_enter = full.get("unsafe_before_validation_enter") or ""
        if _mentions_pdc(after_enter) or _mentions_pdc(before_validation_enter):
            hooks.append(
                HookRef(
                    state_id=state["id"],
                    state_name=state["name"],
                    model_type=state["model_type"],
                    after_enter=after_enter,
                    before_validation_enter=before_validation_enter,
                )
            )
    return hooks
