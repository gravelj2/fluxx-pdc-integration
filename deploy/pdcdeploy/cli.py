"""Command-line entry point.

Usage:
    python -m pdcdeploy.cli --base-url orgname-trn.fluxx.io

The bearer token is never read from an env var or file -- it's prompted for
interactively (and not echoed) each run, so it never lands on disk.

This is read-only: it inventories what's live in Fluxx for the PDC
integration and compares named methods / GrantRequest's PDC hook against a
repo source (default: origin/main, i.e. macfound/fluxx-pdc-integration --
override with --remote/--ref, or use --local to read the working tree on
disk instead). Nothing is written to Fluxx or git. Stencil comparison isn't
built yet -- see docs/roadmap.md's build order for what's deliberately
deferred.
"""

from __future__ import annotations

import argparse
import getpass
import sys

from .compare import ComparisonResult, Status, compare_owned, compare_shared, compare_whole
from .fluxx_client import FluxxApiError, FluxxClient
from .generic_templates import fetch_oauth_callback_element_text, find_grantee_generic_templates
from .git_source import DEFAULT_REF, DEFAULT_REMOTE, GitSource, GitSourceError, WorkingTreeSource
from .hooks import find_grant_request_pdc_hooks
from .manifest import TRACKED_MODEL_TYPES
from .methods import fetch_body, find_tracked_methods
from .paths import OAUTH_CALLBACK_PATH, hook_path, method_path
from .roles import list_roles
from .stencils import find_tracked_stencils, report_missing
from .themes import find_theme_pdc_status


def normalize_base_url(raw: str) -> str:
    raw = raw.strip()
    if not raw.startswith("http"):
        raw = f"https://{raw}"
    return raw.rstrip("/")


STATUS_LABELS = {
    Status.MATCH: "OK",
    Status.DIFFERS: "DIFFERS",
    Status.MISSING_IN_REPO: "MISSING IN REPO",
    Status.MISSING_IN_FLUXX: "MISSING IN FLUXX",
    Status.SKIPPED_SECRET: "skipped (secret)",
    Status.MARKER_NOT_FOUND: "NO PDC MARKERS FOUND",
}


def print_section(title: str) -> None:
    print()
    print(title)
    print("-" * len(title))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inventory PDC integration objects in a Fluxx instance.")
    parser.add_argument(
        "--base-url",
        required=True,
        help="Fluxx instance host, e.g. orgname-trn.fluxx.io",
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Path to the local git checkout to read repo content from (default: current directory's repo).",
    )
    parser.add_argument(
        "--remote",
        default=DEFAULT_REMOTE,
        help=f"Git remote to compare against (default: {DEFAULT_REMOTE}, i.e. macfound/fluxx-pdc-integration).",
    )
    parser.add_argument(
        "--ref",
        default=DEFAULT_REF,
        help=f"Git ref on --remote to compare against (default: {DEFAULT_REF}).",
    )
    parser.add_argument(
        "--local",
        action="store_true",
        help="Compare against the working tree on disk (uncommitted changes included) instead of --remote/--ref.",
    )
    args = parser.parse_args(argv)

    base_url = normalize_base_url(args.base_url)
    token = getpass.getpass(f"Bearer token for {base_url}: ").strip()
    if not token:
        print("No token entered; aborting.", file=sys.stderr)
        return 1

    client = FluxxClient(base_url=base_url, token=token)
    source = (
        WorkingTreeSource(repo_root=args.repo_root)
        if args.local
        else GitSource(repo_root=args.repo_root, remote=args.remote, ref=args.ref)
    )

    try:
        methods_by_model = find_tracked_methods(client)
        hooks = find_grant_request_pdc_hooks(client)
        theme_status = find_theme_pdc_status(client, "GrantRequest", hooks)
        role_list = list_roles(client)
        stencil_refs = find_tracked_stencils(client)
        grantee_templates = find_grantee_generic_templates(client)
    except FluxxApiError as exc:
        print(f"Fluxx API error: {exc}", file=sys.stderr)
        return 1

    print_section("Named methods")
    for model_type, label in {**TRACKED_MODEL_TYPES, "GrantRequest": "GrantRequest"}.items():
        refs = methods_by_model.get(model_type, [])
        print(f"{label} ({model_type}): {len(refs)} method(s)")
        for ref in refs:
            print(f"  [{ref.id}] {ref.name}  (method_type={ref.method_type})")

    print_section("GrantRequest lifecycle hooks (MachineState.unsafe_after_enter)")
    if not hooks:
        print("None found.")
    for hook in hooks:
        print(f"  state[{hook.state_id}] {hook.state_name!r}")

    print_section("GrantRequest theme PDC status")
    for status in theme_status:
        marker = "HAS PDC" if status.has_pdc_hook else "no PDC"
        print(
            f"  theme[{status.theme_id}] {status.theme_name!r} "
            f"workflow[{status.workflow_id}] {status.workflow_name!r} -- {marker} "
            f"{status.reachable_pdc_state_names if status.has_pdc_hook else ''}"
        )

    print_section("Roles (listing only -- not cross-referenced)")
    for role in role_list:
        print(f"  [{role.id}] {role.name} (roleable_type={role.roleable_type})")

    print_section("Stencils")
    for ref in stencil_refs.values():
        print(
            f"  {ref.label:<22} model_type={ref.model_type:<35} "
            f"stencil_id={ref.stencil_id:<8} model_theme_id={ref.model_theme_id:<8} "
            f"updated_at={ref.updated_at}"
        )
    missing = report_missing(stencil_refs)
    for label in missing:
        print(f"  MISSING: no form/list/show stencil found for {label}")

    print_section("Generic Template (grantee-facing, for oauth-callback.html)")
    if not grantee_templates:
        print("No UserProfile found with 'grantee' in categories.")
    if len(grantee_templates) > 1:
        print(f"AMBIGUOUS: {len(grantee_templates)} profiles have 'grantee' in categories -- review each below.")
    for gt in grantee_templates:
        oauth_marker = "contains 'oauth'" if gt.contains_oauth else "no 'oauth' found"
        print(
            f"  profile[{gt.profile_id}] {gt.profile_name!r} -> "
            f"dashboard_template[{gt.dashboard_template_id}] -> "
            f"first_card={gt.first_card_title!r} -> "
            f"stencil[{gt.stencil_id}] {gt.stencil_name!r} ({oauth_marker})"
        )

    source_desc = args.repo_root if args.local else f"{args.remote}/{args.ref}"
    print_section(f"Comparison against repo ({source_desc})")
    try:
        results = _compare_methods(client, methods_by_model, source)
        results += _compare_hooks(hooks, source)
        results += _compare_oauth_callback(client, grantee_templates, source)
    except GitSourceError as exc:
        print(f"Git source error: {exc}", file=sys.stderr)
        return 1

    for result in results:
        print(f"  [{STATUS_LABELS[result.status]}] {result.label}  ({result.repo_path})")

    differing = [r for r in results if r.status in (Status.DIFFERS, Status.MISSING_IN_REPO, Status.MISSING_IN_FLUXX)]
    return 1 if differing else 0


def _compare_methods(
    client: FluxxClient,
    methods_by_model: dict[str, list],
    source: GitSource | WorkingTreeSource,
) -> list[ComparisonResult]:
    results: list[ComparisonResult] = []
    for model_type, refs in methods_by_model.items():
        for ref in refs:
            repo_path = method_path(model_type, ref.name)
            fluxx_body = fetch_body(client, ref.id)
            repo_body = source.read_file(repo_path)
            results.append(compare_owned(ref.name, repo_path, ref.name, fluxx_body, repo_body))
    return results


def _compare_hooks(hooks: list, source: GitSource | WorkingTreeSource) -> list[ComparisonResult]:
    results: list[ComparisonResult] = []
    for hook in hooks:
        try:
            repo_path = hook_path(hook.state_name)
        except KeyError:
            # A PDC-invoking state we don't yet have a repo path for --
            # surface it plainly rather than silently skipping.
            results.append(
                ComparisonResult(hook.state_name, "(no known repo path)", Status.MISSING_IN_REPO)
            )
            continue
        repo_body = source.read_file(repo_path)
        results.append(compare_shared(hook.state_name, repo_path, hook.after_enter, repo_body))
    return results


def _compare_oauth_callback(
    client: FluxxClient, grantee_templates: list, source: GitSource | WorkingTreeSource
) -> list[ComparisonResult]:
    """Compares oauth-callback.html against whichever grantee-profile
    stencil(s) actually resolved to a real stencil id with oauth content --
    see generic_templates.py. A profile with no dashboard template, or a
    dashboard whose first card isn't a GenericTemplate, contributes nothing
    to compare (that's a discovery-chain gap already surfaced in the
    inventory section above, not a content mismatch).
    """
    results: list[ComparisonResult] = []
    repo_body = source.read_file(OAUTH_CALLBACK_PATH)
    for template in grantee_templates:
        if template.stencil_id is None or not template.contains_oauth:
            continue
        label = f"oauth-callback ({template.profile_name} profile, stencil {template.stencil_id})"
        fluxx_body = fetch_oauth_callback_element_text(client, template.stencil_id)
        results.append(compare_whole(label, OAUTH_CALLBACK_PATH, fluxx_body, repo_body))
    return results


if __name__ == "__main__":
    raise SystemExit(main())
