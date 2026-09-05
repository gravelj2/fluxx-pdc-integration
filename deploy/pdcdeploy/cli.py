"""Command-line entry point.

Usage:
    python -m pdcdeploy.cli --base-url macfound-trn.fluxx.io

The bearer token is never read from an env var or file -- it's prompted for
interactively (and not echoed) each run, so it never lands on disk.
"""

from __future__ import annotations

import argparse
import getpass
import sys

from .fluxx_client import FluxxApiError, FluxxClient
from .stencils import find_tracked_stencils, report_missing


def normalize_base_url(raw: str) -> str:
    raw = raw.strip()
    if not raw.startswith("http"):
        raw = f"https://{raw}"
    return raw.rstrip("/")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Look up tracked PDC stencils in a Fluxx instance.")
    parser.add_argument(
        "--base-url",
        required=True,
        help="Fluxx instance host, e.g. macfound-trn.fluxx.io",
    )
    args = parser.parse_args(argv)

    base_url = normalize_base_url(args.base_url)
    token = getpass.getpass(f"Bearer token for {base_url}: ").strip()
    if not token:
        print("No token entered; aborting.", file=sys.stderr)
        return 1

    client = FluxxClient(base_url=base_url, token=token)

    try:
        found = find_tracked_stencils(client)
    except FluxxApiError as exc:
        print(f"Fluxx API error: {exc}", file=sys.stderr)
        return 1

    for ref in found.values():
        ruby_note = ""
        print(
            f"{ref.label:<22} model_type={ref.model_type:<35} "
            f"stencil_id={ref.stencil_id:<8} model_theme_id={ref.model_theme_id:<8} "
            f"updated_at={ref.updated_at}"
        )

    missing = report_missing(found)
    if missing:
        print()
        print("Missing (no form/list/show stencil found for):")
        for label in missing:
            print(f"  - {label}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
