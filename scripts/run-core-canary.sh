#!/usr/bin/env bash

# Builds the application against an already checked-out ManifoldKit revision.
# This script is intentionally suitable for a GitHub-hosted runner and local
# reproduction. It never changes the tracked product dependency pins.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: run-core-canary.sh --core-path PATH --core-ref REF --metadata-dir PATH [options]

Options:
  --app-root PATH          Application checkout (default: current directory)
  --app-ref REF            Requested application ref, recorded in metadata
  --app-sha SHA            Expected resolved application commit
  --core-sha SHA           Expected resolved core commit
  --renderer PATH          Temporary-spec renderer (default: app scripts directory)
  --ios-destination VALUE  xcodebuild iOS destination
EOF
    exit 2
}

fail() {
    printf 'core-canary: %s\n' "$*" >&2
    exit 1
}

is_commit_sha() {
    [[ "$1" =~ ^[0-9a-fA-F]{7,64}$ ]]
}

validate_ref() {
    local name="$1"
    local ref="$2"

    [[ -n "$ref" ]] || fail "$name is required"
    if is_commit_sha "$ref"; then
        return
    fi
    [[ "$ref" != -* ]] || fail "$name must not begin with a dash"
    [[ "$ref" != *$'\n'* && "$ref" != *$'\r'* ]] || fail "$name must be one line"
    git check-ref-format --allow-onelevel "$ref" >/dev/null 2>&1 \
        || fail "$name is not a valid Git ref: $ref"
}

validate_full_sha() {
    local name="$1"
    local sha="$2"

    [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || fail "$name must be a full commit SHA"
}

require_clean_checkout() {
    local name="$1"
    local path="$2"
    local status_output

    status_output="$(git -C "$path" status --porcelain --untracked-files=normal)" \
        || fail "could not inspect $name checkout status: $path"
    [[ -z "$status_output" ]] || fail "$name checkout is dirty: $path"
}

APP_ROOT="$PWD"
APP_REF=""
APP_EXPECTED_SHA=""
CORE_PATH=""
CORE_REF=""
CORE_EXPECTED_SHA=""
METADATA_DIR=""
IOS_DESTINATION="platform=iOS Simulator,name=iPhone 17,OS=26.5"
RENDERER=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --app-root)
            [[ "$#" -ge 2 ]] || usage
            APP_ROOT="$2"
            shift 2
            ;;
        --app-root=*)
            APP_ROOT="${1#*=}"
            shift
            ;;
        --app-ref)
            [[ "$#" -ge 2 ]] || usage
            APP_REF="$2"
            shift 2
            ;;
        --app-ref=*)
            APP_REF="${1#*=}"
            shift
            ;;
        --app-sha)
            [[ "$#" -ge 2 ]] || usage
            APP_EXPECTED_SHA="$2"
            shift 2
            ;;
        --app-sha=*)
            APP_EXPECTED_SHA="${1#*=}"
            shift
            ;;
        --core-path)
            [[ "$#" -ge 2 ]] || usage
            CORE_PATH="$2"
            shift 2
            ;;
        --core-path=*)
            CORE_PATH="${1#*=}"
            shift
            ;;
        --core-ref)
            [[ "$#" -ge 2 ]] || usage
            CORE_REF="$2"
            shift 2
            ;;
        --core-ref=*)
            CORE_REF="${1#*=}"
            shift
            ;;
        --core-sha)
            [[ "$#" -ge 2 ]] || usage
            CORE_EXPECTED_SHA="$2"
            shift 2
            ;;
        --core-sha=*)
            CORE_EXPECTED_SHA="${1#*=}"
            shift
            ;;
        --metadata-dir)
            [[ "$#" -ge 2 ]] || usage
            METADATA_DIR="$2"
            shift 2
            ;;
        --metadata-dir=*)
            METADATA_DIR="${1#*=}"
            shift
            ;;
        --ios-destination)
            [[ "$#" -ge 2 ]] || usage
            IOS_DESTINATION="$2"
            shift 2
            ;;
        --ios-destination=*)
            IOS_DESTINATION="${1#*=}"
            shift
            ;;
        --renderer)
            [[ "$#" -ge 2 ]] || usage
            RENDERER="$2"
            shift 2
            ;;
        --renderer=*)
            RENDERER="${1#*=}"
            shift
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$METADATA_DIR" ]] || usage
mkdir -p "$METADATA_DIR"
METADATA_FILE="$METADATA_DIR/canary-metadata.json"

APP_SHA=""
CORE_SHA=""
XCODEGEN_VERSION="unavailable"
XCODEBUILD_VERSION="unavailable"
CANARY_SPEC=""
PACKAGE_LINK=""
CANARY_SPEC_TEMP=""

write_metadata() {
    local exit_code="$1"
    local status="failed"
    [[ "$exit_code" -eq 0 ]] && status="passed"

    python3 - "$METADATA_FILE" "$status" "$exit_code" "$APP_REF" "$APP_SHA" \
        "$CORE_REF" "$CORE_SHA" "$XCODEGEN_VERSION" "$XCODEBUILD_VERSION" \
        "$IOS_DESTINATION" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    status,
    exit_code,
    app_ref,
    app_sha,
    core_ref,
    core_sha,
    xcodegen_version,
    xcodebuild_version,
    ios_destination,
) = sys.argv[1:]

Path(output).write_text(json.dumps({
    "schemaVersion": 1,
    "status": status,
    "exitCode": int(exit_code),
    "app": {"requestedRef": app_ref, "commit": app_sha},
    "core": {"requestedRef": core_ref, "commit": core_sha},
    "toolchain": {
        "xcodegen": xcodegen_version,
        "xcodebuild": xcodebuild_version,
    },
    "xcodegenPackageIdentity": {
        "package": "ManifoldKit",
        "localPath": "ManifoldKit",
    },
    "iosDestination": ios_destination,
}, indent=2, sort_keys=True) + "\n")
PY
}

cleanup() {
    local exit_code="$?"
    local terminal_exit
    local cleanup_failed=0
    set +e
    if [[ -n "$PACKAGE_LINK" && -L "$PACKAGE_LINK" ]]; then
        /bin/rm "$PACKAGE_LINK" || cleanup_failed=1
    fi
    if [[ -n "$CANARY_SPEC" && -f "$CANARY_SPEC" ]]; then
        /bin/rm "$CANARY_SPEC" || cleanup_failed=1
    fi
    if [[ -n "$CANARY_SPEC_TEMP" && -f "$CANARY_SPEC_TEMP" ]]; then
        /bin/rm "$CANARY_SPEC_TEMP" || cleanup_failed=1
    fi
    if [[ "${CANARY_TEST_FORCE_CLEANUP_FAILURE:-}" == '1' ]]; then
        # Offline self-test hook: prove a cleanup failure cannot attest pass.
        cleanup_failed=1
    fi
    terminal_exit="$exit_code"
    if [[ "$terminal_exit" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
        terminal_exit=1
    fi
    write_metadata "$terminal_exit" || {
        echo 'core-canary: failed to write terminal metadata' >&2
        exit 1
    }
    if [[ "$terminal_exit" -ne "$exit_code" ]]; then
        echo 'core-canary: cleanup failed' >&2
    fi
    exit "$terminal_exit"
}
trap cleanup EXIT

validate_ref "core ref" "$CORE_REF"
if [[ -n "$APP_REF" ]]; then
    validate_ref "app ref" "$APP_REF"
fi
if [[ -n "$APP_EXPECTED_SHA" ]]; then
    validate_full_sha "app SHA" "$APP_EXPECTED_SHA"
fi
if [[ -n "$CORE_EXPECTED_SHA" ]]; then
    validate_full_sha "core SHA" "$CORE_EXPECTED_SHA"
fi

[[ -d "$APP_ROOT" ]] || fail "app root does not exist: $APP_ROOT"
[[ -d "$CORE_PATH" ]] || fail "core path does not exist: $CORE_PATH"
[[ -f "$APP_ROOT/project.yml" ]] || fail "app root has no project.yml: $APP_ROOT"
[[ -f "$CORE_PATH/Package.swift" ]] || fail "core path has no Package.swift: $CORE_PATH"

APP_ROOT="$(cd "$APP_ROOT" && pwd -P)"
CORE_PATH="$(cd "$CORE_PATH" && pwd -P)"
APP_SHA="$(git -C "$APP_ROOT" rev-parse --verify HEAD^{commit})"
CORE_SHA="$(git -C "$CORE_PATH" rev-parse --verify HEAD^{commit})"
require_clean_checkout "application" "$APP_ROOT"
require_clean_checkout "core" "$CORE_PATH"
if [[ -n "$APP_EXPECTED_SHA" ]]; then
    [[ "$APP_SHA" == "$APP_EXPECTED_SHA" ]] || fail "application checkout does not match expected SHA"
else
    [[ -z "$APP_REF" || "$APP_SHA" == "$(git -C "$APP_ROOT" rev-parse --verify "$APP_REF^{commit}")" ]] \
        || fail "application checkout does not match requested ref"
fi
if [[ -n "$CORE_EXPECTED_SHA" ]]; then
    [[ "$CORE_SHA" == "$CORE_EXPECTED_SHA" ]] || fail "core checkout does not match expected SHA"
else
    [[ "$CORE_SHA" == "$(git -C "$CORE_PATH" rev-parse --verify "$CORE_REF^{commit}")" ]] \
        || fail "core checkout does not match requested ref"
fi

package_link_path="$APP_ROOT/ManifoldKit"
if [[ -e "$package_link_path" || -L "$package_link_path" ]]; then
    fail "refusing to replace existing package identity path: $package_link_path"
fi
ln -s "$CORE_PATH" "$package_link_path"
PACKAGE_LINK="$package_link_path"

canary_spec_path="$APP_ROOT/.project.core-canary.yml"
if [[ -e "$canary_spec_path" || -L "$canary_spec_path" ]]; then
    fail "refusing to replace existing temporary XcodeGen spec: $canary_spec_path"
fi
if [[ -z "$RENDERER" ]]; then
    RENDERER="$APP_ROOT/scripts/prepare-core-canary-spec.py"
fi
[[ -f "$RENDERER" ]] || fail "temporary-spec renderer does not exist: $RENDERER"
CANARY_SPEC_TEMP="$canary_spec_path.tmp.$$"
python3 "$RENDERER" "$APP_ROOT/project.yml" "$CANARY_SPEC_TEMP"
mv "$CANARY_SPEC_TEMP" "$canary_spec_path"
CANARY_SPEC_TEMP=""
CANARY_SPEC="$canary_spec_path"

CANARY_XCODEGEN="${CANARY_XCODEGEN:-xcodegen}"
CANARY_XCODEBUILD="${CANARY_XCODEBUILD:-xcodebuild}"
XCODEGEN_VERSION="$($CANARY_XCODEGEN --version)"
XCODEBUILD_VERSION="$($CANARY_XCODEBUILD -version)"

cd "$APP_ROOT"
"$CANARY_XCODEGEN" generate --spec "$CANARY_SPEC" --project "$APP_ROOT" --project-root "$APP_ROOT"

common_args=(
    -project Manifold.xcodeproj
    -skipPackagePluginValidation
    CODE_SIGNING_ALLOWED=NO
)
test_args=(
    -project Manifold.xcodeproj
    -skipPackagePluginValidation
)

"$CANARY_XCODEBUILD" build "${common_args[@]}" \
    -scheme Manifold \
    -destination "$IOS_DESTINATION"
"$CANARY_XCODEBUILD" build "${common_args[@]}" \
    -scheme ManifoldMac \
    -destination 'platform=macOS'
bash "$APP_ROOT/scripts/test-ios-device.sh" --self-test
"$CANARY_XCODEBUILD" test "${test_args[@]}" \
    -scheme Manifold \
    -destination "$IOS_DESTINATION" \
    -resultBundlePath "$METADATA_DIR/Manifold-iOS.xcresult"
"$CANARY_XCODEBUILD" test "${test_args[@]}" \
    -scheme ManifoldMac \
    -destination 'platform=macOS' \
    -resultBundlePath "$METADATA_DIR/Manifold-macOS.xcresult"

printf 'core-canary: passed app=%s core=%s\n' "$APP_SHA" "$CORE_SHA"
