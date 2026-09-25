"""Compare live Fluxx content against a repo source, per docs/roadmap.md.

Two ownership regimes (per the user, 2026-09-24):

- Fully-owned surfaces (the 3 PDC dynamic models' methods/stencils, and
  GrantRequest's own "PDC "-prefixed methods): nothing else is deployed
  there, so a whole-body diff is correct.
- Shared surfaces (GrantRequest's lifecycle hooks, and stencils on
  GrantRequest / GenericTemplate): these may carry other teams' Ruby or
  layout we must never touch or flag. Only the content between
  MARKER_START/MARKER_END is ours to compare; everything outside those
  markers is explicitly ignored, in both directions.

Secret methods (manifest.SECRET_METHOD_NAMES) are never diffed -- the repo
copy is an intentional placeholder, see docs/deployment.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .manifest import MARKER_END, MARKER_START, SECRET_METHOD_NAMES, STENCIL_ELEMENT_MARKER_PREFIX


class Status(Enum):
    MATCH = "match"
    DIFFERS = "differs"
    MISSING_IN_REPO = "missing_in_repo"  # live in Fluxx, no repo file
    MISSING_IN_FLUXX = "missing_in_fluxx"  # repo file exists, nothing live
    SKIPPED_SECRET = "skipped_secret"
    MARKER_NOT_FOUND = "marker_not_found"  # shared surface, but no PDC block present


@dataclass(frozen=True)
class ComparisonResult:
    label: str
    repo_path: str
    status: Status
    fluxx_content: str | None = None
    repo_content: str | None = None


def extract_marked_section(text: str | None) -> str | None:
    """Pull out just the MARKER_START..MARKER_END section (markers included,
    so a whitespace/marker-placement change is still visible as a diff).
    None if the text is None or doesn't contain the markers at all.
    """
    if text is None:
        return None
    start = text.find(MARKER_START)
    end = text.find(MARKER_END)
    if start == -1 or end == -1:
        return None
    return text[start : end + len(MARKER_END)]


def compare_owned(
    label: str, repo_path: str, method_name: str, fluxx_body: str | None, repo_body: str | None
) -> ComparisonResult:
    """Whole-body comparison for a fully-owned method/stencil."""
    if method_name in SECRET_METHOD_NAMES:
        return ComparisonResult(label, repo_path, Status.SKIPPED_SECRET)
    return compare_whole(label, repo_path, fluxx_body, repo_body)


def compare_whole(label: str, repo_path: str, fluxx_body: str | None, repo_body: str | None) -> ComparisonResult:
    """Whole-content comparison with no secret check -- for a fully-owned
    element found by something other than an exact method name (e.g. the
    oauth-callback element inside a GenericTemplate stencil, located by
    substring rather than by a name lookup). `compare_owned` delegates here
    after its secret check.
    """
    if fluxx_body is None and repo_body is None:
        # Neither side has it -- not a real object, nothing to report.
        return ComparisonResult(label, repo_path, Status.MISSING_IN_FLUXX)
    if fluxx_body is not None and repo_body is None:
        return ComparisonResult(label, repo_path, Status.MISSING_IN_REPO, fluxx_content=fluxx_body)
    if fluxx_body is None and repo_body is not None:
        return ComparisonResult(label, repo_path, Status.MISSING_IN_FLUXX, repo_content=repo_body)

    if _normalize(fluxx_body) == _normalize(repo_body):
        return ComparisonResult(label, repo_path, Status.MATCH)
    return ComparisonResult(
        label, repo_path, Status.DIFFERS, fluxx_content=fluxx_body, repo_content=repo_body
    )


def compare_shared(label: str, repo_path: str, fluxx_full_body: str | None, repo_body: str | None) -> ComparisonResult:
    """Marker-extracted comparison for a shared surface (GrantRequest hooks,
    GrantRequest/GenericTemplate stencils). Only ever looks at the
    MARKER_START..MARKER_END slice -- content outside it belongs to other
    teams and is never read, reported, or compared.
    """
    fluxx_section = extract_marked_section(fluxx_full_body)
    repo_section = extract_marked_section(repo_body)

    if fluxx_full_body is not None and fluxx_section is None:
        # The shared surface exists but has no PDC markers in it at all --
        # distinct from "differs", since there's no PDC content to diff
        # against, only its total absence.
        return ComparisonResult(label, repo_path, Status.MARKER_NOT_FOUND, fluxx_content=fluxx_full_body)

    if fluxx_section is None and repo_section is None:
        return ComparisonResult(label, repo_path, Status.MISSING_IN_FLUXX)
    if fluxx_section is not None and repo_section is None:
        return ComparisonResult(label, repo_path, Status.MISSING_IN_REPO, fluxx_content=fluxx_section)
    if fluxx_section is None and repo_section is not None:
        return ComparisonResult(label, repo_path, Status.MISSING_IN_FLUXX, repo_content=repo_section)

    if _normalize(fluxx_section) == _normalize(repo_section):
        return ComparisonResult(label, repo_path, Status.MATCH)
    return ComparisonResult(
        label, repo_path, Status.DIFFERS, fluxx_content=fluxx_section, repo_content=repo_section
    )


def find_stencil_element_text(elements: list[dict], element_id: str) -> str | None:
    """Locate a PDC-owned element within a Stencil.json `elements` tree by
    its `<!-- PDC:ELEMENT id=... -->` marker (see manifest.py) rather than by
    `uid` (per-instance, not portable) or by content substring (ambiguous
    once more than one PDC element exists in the same stencil). Returns the
    element's raw `config.text` (still HTML-entity-encoded as Fluxx stores
    it -- callers decode with `html.unescape` before diffing against a repo
    file, same as generic_templates.py's oauth-callback handling).

    Recurses into `group` elements' nested `elements` -- confirmed on TRN
    (2026-09-25): GrantRequest's form stencils keep all 7 PDC blocks (the 6
    Data Explorer files plus the readonly stencil-container variant) nested
    one level inside a "Contribute to the Philanthropy Data Commons (PDC)"
    group, unlike the flat GenericTemplate stencil this function was first
    written against. A top-level-only search would silently return None for
    every GrantRequest block.
    """
    marker = f"{STENCIL_ELEMENT_MARKER_PREFIX}{element_id} -->"
    for element in elements:
        text = (element.get("config") or {}).get("text")
        if text and marker in text:
            return text
        nested = element.get("elements")
        if nested:
            found = find_stencil_element_text(nested, element_id)
            if found is not None:
                return found
    return None


def _normalize(text: str) -> str:
    """CRLF-vs-LF and trailing-whitespace are not meaningful drift for Ruby
    pasted through Fluxx's admin textareas -- normalize before comparing so
    those don't show up as false positives.
    """
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").splitlines()).strip()
