"""Repo-side source of truth: which dynamic model types this tool tracks, and
which named methods on them are exempt from content comparison because they
hold a real secret in Fluxx but a placeholder in the repo.

Model type names use REST/Liquid casing (`Pdc`), matching what the Fluxx REST
API returns -- see docs/architecture.md's casing note and the
fluxx-rest-api-facts memory for why this differs from the `PDC` casing used in
some Ruby file headers.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# Fluxx model_type -> human label, for readable output only.
TRACKED_MODEL_TYPES: dict[str, str] = {
    "MacModelTypeDynPdcConsent": "PDC Consent",
    "MacModelTypeDynPdcApplicationForm1": "PDC Integration Map",
    "MacModelTypeDynPdcMappedField1": "PDC Mapped Field",
}

# Named methods whose repo copy is intentionally a placeholder, not the real
# body -- comparing these against Fluxx would always report a false mismatch.
# See docs/deployment.md "Environment & secrets checklist".
SECRET_METHOD_NAMES: frozenset[str] = frozenset(
    {
        "Get PDC Client ID",
        "Get PDC Client Secret",
    }
)


@dataclass(frozen=True)
class RepoMethod:
    model_type: str
    name: str
    repo_path: str
    is_secret: bool = field(default=False)

    def __post_init__(self) -> None:
        if self.name in SECRET_METHOD_NAMES:
            object.__setattr__(self, "is_secret", True)
