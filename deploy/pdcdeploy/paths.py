"""Map a Fluxx object to the repo-relative path that should hold its content.

Naming is a strict 1:1 convention already in use across the repo: a method
or hook named "X" lives at "<folder>/X.rb" (verbatim, spaces and all -- see
docs/deployment.md "What goes where"). This module only encodes the
model_type -> folder part; the filename itself is always just `f"{name}.rb"`.
"""

from __future__ import annotations

MODEL_TYPE_FOLDERS: dict[str, str] = {
    "GrantRequest": "pdc-map/grant-request",
    "MacModelTypeDynPdcApplicationForm1": "pdc-map/pdc-integration-map",
    "MacModelTypeDynPdcMappedField1": "pdc-map/pdc-mapped-field",
    "MacModelTypeDynPdcConsent": "pdc-map/pdc-consent",
}


def method_path(model_type: str, method_name: str) -> str:
    folder = MODEL_TYPE_FOLDERS[model_type]
    return f"{folder}/{method_name}.rb"


def hook_path(state_name: str) -> str:
    """GrantRequest's marker-delimited hooks are named "PDC AfterEnter -
    <State>.rb"-style in the repo -- currently there's only the one
    (`PDC After Enter - Send to PDC.rb`) for the `granted` state, so this
    is a small explicit lookup rather than a general naming rule until a
    second hook proves out the pattern.
    """
    known = {
        "granted": "pdc-map/grant-request/PDC After Enter - Send to PDC.rb",
    }
    if state_name not in known:
        raise KeyError(f"no known repo path for a PDC hook on GrantRequest state {state_name!r}")
    return known[state_name]


OAUTH_CALLBACK_PATH = "data-explorer/oauth-callback.html"
