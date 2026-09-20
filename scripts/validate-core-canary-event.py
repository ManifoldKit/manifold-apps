#!/usr/bin/env python3
"""Validate GitHub event refs before exporting them to the canary job."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


SHA = re.compile(r"[0-9a-fA-F]{7,64}\Z")


def ref_from(payload: object, field: str) -> str:
    if not isinstance(payload, dict):
        raise ValueError("canary input payload must be an object")
    ref = payload.get(field)
    if not isinstance(ref, str) or not ref:
        raise ValueError(f"{field} must be a non-empty string")
    if ref.startswith("-") or "\n" in ref or "\r" in ref:
        raise ValueError(f"{field} must be a single-line Git ref without a leading dash")
    if not SHA.fullmatch(ref):
        result = subprocess.run(
            ["git", "check-ref-format", "--allow-onelevel", ref],
            check=False,
            capture_output=True,
        )
        if result.returncode != 0:
            raise ValueError(f"{field} is not a valid Git ref")
    return ref


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--event-path", required=True, type=Path)
    parser.add_argument("--github-env", required=True, type=Path)
    args = parser.parse_args()

    try:
        event = json.loads(args.event_path.read_text())
        if not isinstance(event, dict):
            raise ValueError("GitHub event must be an object")
        if args.event_name == "repository_dispatch":
            payload = event.get("client_payload")
        elif args.event_name == "workflow_dispatch":
            payload = event.get("inputs")
        else:
            raise ValueError("unsupported canary event")
        app_ref = ref_from(payload, "app_ref")
        core_ref = ref_from(payload, "core_ref")
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"core-canary inputs: {error}", file=sys.stderr)
        return 2

    # Neither variable is exported until *both* values have passed validation.
    with args.github_env.open("a") as environment:
        environment.write(f"APP_REF={app_ref}\nCORE_REF={core_ref}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
