"""Repo-side source of truth: which dynamic model types this tool tracks, and
which named methods on them are exempt from content comparison because they
hold a real secret in Fluxx but a placeholder in the repo.

Model type names use REST/Liquid casing (`Pdc`), matching what the Fluxx REST
API returns -- see docs/architecture.md's casing note and the
fluxx-rest-api-facts memory for why this differs from the `PDC` casing used in
some Ruby file headers.
"""

from __future__ import annotations

# Fluxx model_type -> human label, for readable output only.
TRACKED_MODEL_TYPES: dict[str, str] = {
    "MacModelTypeDynPdcConsent": "PDC Consent",
    "MacModelTypeDynPdcApplicationForm1": "PDC Integration Map",
    "MacModelTypeDynPdcMappedField1": "PDC Mapped Field",
}

# GrantRequest carries hundreds of methods unrelated to PDC (tax handling,
# other programs' workflows, zzDEV scratch methods, ...). Per the naming
# convention (all GrantRequest methods belonging to this integration are
# named with a "PDC " prefix), a prefix check identifies them -- not a bare
# substring, which would also match an unrelated method that merely mentions
# PDC in passing (confirmed on TRN: a General Operations state's comment
# says "retired PDC's or Candid codes" with no PDC invocation at all).
PDC_NAME_PREFIX = "PDC "


def is_grant_request_pdc_method(name: str) -> bool:
    """True if a GrantRequest ModelMethod name follows the "PDC " prefix
    convention. `PDC_Get_PDC_Field_Mapping` and `PDC_Get_Data_Preview_For_Proposal`
    use an underscore instead of a space after PDC but still start with the
    literal "PDC" token, so this checks the un-spaced prefix too.
    """
    return name.startswith(PDC_NAME_PREFIX) or name.startswith("PDC_")


# Model types whose content is fully owned by this integration -- nothing
# else is deployed there, so a whole-body diff against the repo is safe.
# GrantRequest is NOT in this set: its lifecycle hooks and stencil are shared
# with unrelated Fluxx configuration (see MARKER_START/MARKER_END below).
# GrantRequest's own named PDC methods (is_grant_request_pdc_method) ARE
# fully owned, though -- a method is either wholly ours or not deployed at
# all, unlike a hook/stencil which can interleave our content with others'.
FULLY_OWNED_MODEL_TYPES: frozenset[str] = frozenset(TRACKED_MODEL_TYPES) | frozenset({"GrantRequest"})

# Marker convention for PDC content injected into a surface this
# integration does NOT fully own (GrantRequest's lifecycle hooks, and
# stencils on GrantRequest / GenericTemplate). Comparison must extract only
# the delimited section from both sides and diff that -- never the whole
# field/element tree, which may carry other teams' Ruby or layout.
MARKER_START = "###PDC_CODE###"
MARKER_END = "###END_PDC_CODE###"

# Fluxx model_type -> the GrantRequest state(s) confirmed to carry a PDC
# invocation in MachineState.unsafe_after_enter (NOT ModelTheme's
# before_new/after_create -- see docs/roadmap.md). This is TRN-specific
# and will need re-discovering per environment; hardcoded here only because
# state names, unlike ids, are expected to be stable across environments.
GRANT_REQUEST_PDC_STATE_NAMES: frozenset[str] = frozenset({"granted"})

# Named methods whose repo copy is intentionally a placeholder, not the real
# body -- comparing these against Fluxx would always report a false mismatch.
# See docs/deployment.md "Environment & secrets checklist".
SECRET_METHOD_NAMES: frozenset[str] = frozenset(
    {
        "Get PDC Client ID",
        "Get PDC Client Secret",
    }
)
