"""Read repo file contents at a chosen point in git history.

Resolves a (remote, ref) pair to file contents via `git show <ref>:<path>` --
no GitHub API, no new dependency, works entirely offline against whatever
this local clone has already fetched. This is deliberate: it gets the same
"diff against a specific, named commit" property an API-based approach would,
without taking on network calls or auth beyond what's already needed for the
Fluxx side. See docs/roadmap.md for why this was chosen over alternatives.

Supports comparing against someone's fork that hasn't been upstreamed yet --
add it as a second remote (`git remote add <name> <url>`) and pass
`--remote <name>` (see cli.py). A remote's refs are only resolvable after
`git fetch <remote>`; this module fetches automatically when a ref can't be
resolved, so a stale remote doesn't silently compare against old content.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

DEFAULT_REMOTE = "origin"
DEFAULT_REF = "main"
DEFAULT_REPO_URL = "https://github.com/macfound/fluxx-pdc-integration"


class GitSourceError(RuntimeError):
    """Raised when a ref can't be resolved even after fetching."""


@dataclass(frozen=True)
class GitSource:
    repo_root: str
    remote: str = DEFAULT_REMOTE
    ref: str = DEFAULT_REF

    @property
    def resolved_ref(self) -> str:
        """The ref to pass to `git show`. A bare branch name like "main" is
        ambiguous between a local branch and one on `remote` that happens to
        share the name -- qualify it as `<remote>/<ref>` unless the caller
        already gave a fully-qualified ref (a remote/branch pair, a tag, or a
        raw commit SHA).
        """
        if "/" in self.ref or _looks_like_sha(self.ref):
            return self.ref
        return f"{self.remote}/{self.ref}"

    def _run_git(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", self.repo_root, *args],
            capture_output=True,
            text=True,
        )

    def _ensure_fetched(self) -> None:
        result = self._run_git("fetch", self.remote)
        if result.returncode != 0:
            raise GitSourceError(
                f"could not fetch remote {self.remote!r}: {result.stderr.strip()}"
            )

    def read_file(self, repo_relative_path: str) -> str | None:
        """Contents of `repo_relative_path` at `resolved_ref`, or None if the
        file doesn't exist at that ref (a real "missing", not an error).
        """
        result = self._run_git("show", f"{self.resolved_ref}:{repo_relative_path}")
        if result.returncode == 0:
            return result.stdout

        if _is_missing_path_error(result.stderr):
            return None

        # Ref itself may not be resolvable yet -- fetch once and retry before
        # giving up, so a stale remote doesn't look like a missing file.
        self._ensure_fetched()
        retry = self._run_git("show", f"{self.resolved_ref}:{repo_relative_path}")
        if retry.returncode == 0:
            return retry.stdout
        if _is_missing_path_error(retry.stderr):
            return None
        raise GitSourceError(
            f"git show {self.resolved_ref}:{repo_relative_path} -> {retry.stderr.strip()}"
        )


def _looks_like_sha(ref: str) -> bool:
    return len(ref) >= 7 and all(c in "0123456789abcdef" for c in ref.lower())


def _is_missing_path_error(stderr: str) -> bool:
    return "does not exist" in stderr or "exists on disk, but not in" in stderr


@dataclass(frozen=True)
class WorkingTreeSource:
    """Reads whatever is actually on disk right now, uncommitted changes
    included. Same `read_file` interface as GitSource so callers can treat
    "compare against my local edits" and "compare against a specific ref"
    interchangeably -- this is the "--local" escape hatch for testing changes
    before they're committed anywhere.
    """

    repo_root: str

    def read_file(self, repo_relative_path: str) -> str | None:
        path = Path(self.repo_root) / repo_relative_path
        if not path.is_file():
            return None
        return path.read_text()
