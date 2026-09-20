#!/usr/bin/env python3
"""Offline checks for the workflow boundary before the canary runner starts."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github/workflows/core-canary.yml").read_text()
VALIDATOR = ROOT / "scripts/validate-core-canary-event.py"
EARLY_WRITER = ROOT / "scripts/write-core-canary-early-metadata.py"


def assert_workflow_boundary() -> None:
    steps = [line.strip() for line in WORKFLOW.splitlines() if line.strip().startswith("- name: ")]
    expected_order = [
        "- name: Check out canary implementation",
        "- name: Initialize evidence directory",
        "- name: Validate event inputs",
        "- name: Set up Xcode 26.6",
        "- name: Install XcodeGen",
        "- name: Check out requested application revision",
        "- name: Record early terminal failure",
        "- name: Upload canary evidence",
    ]
    positions = [steps.index(step) for step in expected_order]
    assert positions == sorted(positions), "evidence/validation must precede provisioning"
    assert 'metadata_dir="$RUNNER_TEMP/manifold-core-canary"' in WORKFLOW
    assert 'metadata_dir="${METADATA_DIR:-$RUNNER_TEMP/manifold-core-canary}"' in WORKFLOW
    assert 'path: ${{ runner.temp }}/manifold-core-canary' in WORKFLOW
    assert "${{ github.event.client_payload" not in WORKFLOW
    assert "${{ inputs." not in WORKFLOW
    assert "--event-path=\"$GITHUB_EVENT_PATH\"" in WORKFLOW
    assert "--app-ref=\"${APP_REF:-}\"" in WORKFLOW
    assert "--core-ref=\"${CORE_REF:-}\"" in WORKFLOW
    assert "if: always()" in WORKFLOW


def validate_event(
    temp: Path, name: str, event: dict[str, object], should_pass: bool
) -> tuple[Path, Path]:
    event_path = temp / "event.json"
    environment_path = temp / "github-env"
    event_path.write_text(json.dumps(event))
    environment_path.write_text("BEFORE=untouched\n")
    result = subprocess.run(
        [sys.executable, str(VALIDATOR), "--event-name", name,
         "--event-path", str(event_path), "--github-env", str(environment_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) == should_pass, result.stderr
    contents = environment_path.read_text()
    if should_pass:
        assert contents == "BEFORE=untouched\nAPP_REF=main\nCORE_REF=abcdef1234567\n"
    else:
        assert contents == "BEFORE=untouched\n", "invalid refs escaped into job env"
    return event_path, environment_path


def main() -> None:
    assert_workflow_boundary()
    with tempfile.TemporaryDirectory(prefix="manifold-canary-workflow-") as directory:
        temp = Path(directory)
        for name, key in (("repository_dispatch", "client_payload"),
                          ("workflow_dispatch", "inputs")):
            valid = {"app_ref": "main", "core_ref": "abcdef1234567"}
            validate_event(temp, name, {key: valid}, True)
            for payload in (
                None,
                {},
                {"app_ref": "main"},
                {"app_ref": "main", "core_ref": None},
                {"app_ref": "main", "core_ref": 42},
                {"app_ref": "main", "core_ref": ["main"]},
                {"app_ref": False, "core_ref": "main"},
                {"app_ref": "main", "core_ref": ""},
                {"app_ref": "main", "core_ref": "-bad"},
                {"app_ref": "main", "core_ref": "main\nINJECT=1"},
                {"app_ref": "main", "core_ref": "../bad"},
            ):
                validate_event(temp, name, {key: payload}, False)

        # An Xcode provisioning failure happens after validation but before
        # the runner: the workflow's always() writer still has a stable path.
        output = temp / "evidence/canary-metadata.json"
        subprocess.run(
            [sys.executable, str(EARLY_WRITER), "--output", str(output),
             "--app-ref=main", "--core-ref=abcdef1234567",
             "--app-path", str(temp / "no-app"),
             "--core-path", str(temp / "no-core"),
             "--reason", "workflow stopped before the canary runner (failure)"],
            check=True,
        )
        metadata = json.loads(output.read_text())
        assert metadata["status"] == "failed" and metadata["phase"] == "before-runner"
        assert metadata["app"]["requestedRef"] == "main"
        assert metadata["core"]["requestedRef"] == "abcdef1234567"

        # Invalid input means refs have never been exported. The same writer
        # must still accept empty refs and produce terminal failure evidence.
        invalid = temp / "invalid/canary-metadata.json"
        subprocess.run(
            [sys.executable, str(EARLY_WRITER), "--output", str(invalid),
             "--app-ref=", "--core-ref=", "--app-path", str(temp / "no-app"),
             "--core-path", str(temp / "no-core"), "--reason", "validation failed"],
            check=True,
        )
        assert json.loads(invalid.read_text())["status"] == "failed"
    print("core-canary workflow self-test passed")


if __name__ == "__main__":
    main()
