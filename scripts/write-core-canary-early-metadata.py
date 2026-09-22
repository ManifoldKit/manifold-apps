#!/usr/bin/env python3
"""Write fail-closed evidence when a canary stops before its runner starts."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def git_value(path: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(
            ["git", "-C", str(path), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    return completed.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app-ref", required=True)
    parser.add_argument("--core-ref", required=True)
    parser.add_argument("--app-path", required=True, type=Path)
    parser.add_argument("--core-path", required=True, type=Path)
    parser.add_argument("--reason", required=True)
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        "schemaVersion": 1,
        "status": "failed",
        "exitCode": 1,
        "phase": "before-runner",
        "reason": args.reason,
        "app": {
            "requestedRef": args.app_ref,
            "commit": git_value(args.app_path, "rev-parse", "--verify", "HEAD^{commit}"),
        },
        "core": {
            "requestedRef": args.core_ref,
            "commit": git_value(args.core_path, "rev-parse", "--verify", "HEAD^{commit}"),
        },
        "toolchain": {"xcodegen": "unavailable", "xcodebuild": "unavailable"},
        "xcodegenPackageIdentity": {"package": "ManifoldKit", "localPath": "ManifoldKit"},
    }, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
