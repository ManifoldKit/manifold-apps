#!/usr/bin/env python3
"""Render the temporary XcodeGen spec used by the ManifoldKit main canary.

The production spec deliberately consumes published releases.  This tool makes
the smallest possible, checked change for an isolated canary workspace: it
replaces the ManifoldKit package declaration with the local package identity
``ManifoldKit``.  The caller creates that path as a symlink to the requested
core checkout.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


PACKAGE_HEADER = "packages:\n"
PACKAGE_NAME = "  ManifoldKit:\n"
LOCAL_PACKAGE = "  ManifoldKit:\n    path: ManifoldKit\n"


def render(source: str) -> str:
    """Replace exactly one top-level ManifoldKit package declaration."""
    if source.count(PACKAGE_HEADER) != 1:
        raise ValueError("expected exactly one packages: section")
    if source.count(PACKAGE_NAME) != 1:
        raise ValueError("expected exactly one ManifoldKit package declaration")

    lines = source.splitlines(keepends=True)
    start_line = lines.index(PACKAGE_NAME)
    end_line = next(
        (
            index
            for index in range(start_line + 1, len(lines))
            if lines[index].startswith("  ") and not lines[index].startswith("   ")
        ),
        None,
    )
    if end_line is None:
        raise ValueError("ManifoldKit package declaration has no following package")

    original = "".join(lines[start_line:end_line])
    if "    url:" not in original or "    minorVersion:" not in original:
        raise ValueError("ManifoldKit package declaration is not the published-tag form")
    if "    path:" in original:
        raise ValueError("ManifoldKit package declaration is already local")

    return "".join(lines[:start_line]) + LOCAL_PACKAGE + "".join(lines[end_line:])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    try:
        rendered = render(args.source.read_text())
    except (OSError, ValueError) as error:
        print(f"prepare-core-canary-spec: {error}", file=sys.stderr)
        return 2

    args.output.write_text(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
