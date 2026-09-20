#!/usr/bin/env bash

# Offline contract tests for the app/core canary. The fake tools make every
# guard runnable without Xcode, a simulator, a network checkout, or packages.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-core-canary.sh"
RENDERER="$REPO_ROOT/scripts/prepare-core-canary-spec.py"
EARLY_METADATA_WRITER="$REPO_ROOT/scripts/write-core-canary-early-metadata.py"
python3 "$REPO_ROOT/scripts/test-core-canary-workflow.py"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/manifold-core-canary-test.XXXXXX")"
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT

fail() {
    printf 'core-canary self-test: %s\n' "$*" >&2
    exit 1
}

assert_failed() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$description unexpectedly succeeded"
    fi
}

read_status() {
    python3 - "$1" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["status"])
PY
}

read_commit() {
    python3 - "$1" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1]))
print(metadata["app"]["commit"])
PY
}

make_checkout() {
    local path="$1"
    mkdir -p "$path/scripts"
    cat > "$path/project.yml" <<'EOF'
name: Fixture
packages:
  ManifoldKit:
    url: https://github.com/ManifoldKit/ManifoldKit
    minorVersion: 0.78.0
  Other:
    url: https://example.invalid/Other
    minorVersion: 1.0.0
EOF
    cp "$RENDERER" "$path/scripts/prepare-core-canary-spec.py"
    cp "$REPO_ROOT/scripts/test-ios-device.sh" "$path/scripts/test-ios-device.sh"
    git -C "$path" init -q
    git -C "$path" config user.email canary@example.invalid
    git -C "$path" config user.name Canary
    git -C "$path" add project.yml scripts/prepare-core-canary-spec.py scripts/test-ios-device.sh
    git -C "$path" -c commit.gpgsign=false commit -qm fixture
    git -C "$path" branch -M main
}

make_core_checkout() {
    local path="$1"
    mkdir -p "$path"
    printf '// fixture\n' > "$path/Package.swift"
    git -C "$path" init -q
    git -C "$path" config user.email canary@example.invalid
    git -C "$path" config user.name Canary
    git -C "$path" add Package.swift
    git -C "$path" -c commit.gpgsign=false commit -qm fixture
    git -C "$path" branch -M main
}

make_fake_tools() {
    local path="$1"
    mkdir -p "$path"
    cat > "$path/xcodegen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then echo 'XcodeGen fixture'; exit 0; fi
[[ "${CANARY_TEST_FAIL_STAGE:-}" != "xcodegen" ]] || exit 61
printf '%s\n' "$*" >> "$CANARY_TEST_LOG"
spec=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == '--spec' ]]; then spec="$2"; shift 2; continue; fi
  shift
done
grep -Fq 'path: ManifoldKit' "$spec"
EOF
    cat > "$path/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then echo 'Xcode fixture'; exit 0; fi
printf '%s\n' "$*" >> "$CANARY_TEST_LOG"
if [[ "${CANARY_TEST_FAIL_STAGE:-}" == "build" && "${1:-}" == 'build' ]]; then exit 62; fi
if [[ "${CANARY_TEST_FAIL_STAGE:-}" == "test" && "${1:-}" == 'test' ]]; then exit 63; fi
EOF
    chmod +x "$path/xcodegen" "$path/xcodebuild"
}

make_fake_git() {
    local path="$1"
    mkdir -p "$path"
    cat > "$path/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-C' && "${2:-}" == "$CANARY_TEST_STATUS_FAIL_PATH" && "${3:-}" == 'status' ]]; then
    echo 'simulated git status failure' >&2
    printf 'injected\n' > "$CANARY_TEST_STATUS_MARKER"
    exit 73
fi
exec "$CANARY_REAL_GIT" "$@"
EOF
    chmod +x "$path/git"
}

APP="$TEMP_ROOT/app"
CORE="$TEMP_ROOT/core"
TOOLS="$TEMP_ROOT/tools"
FAKE_GIT="$TEMP_ROOT/fakegit"
make_checkout "$APP"
make_core_checkout "$CORE"
make_fake_tools "$TOOLS"
make_fake_git "$FAKE_GIT"
SOURCE_COPY="$TEMP_ROOT/project-before.yml"
cp "$APP/project.yml" "$SOURCE_COPY"

RENDERED_REAL="$TEMP_ROOT/real-project.canary.yml"
python3 "$RENDERER" "$REPO_ROOT/project.yml" "$RENDERED_REAL"
python3 - "$REPO_ROOT/project.yml" "$RENDERED_REAL" <<'PY'
import sys
source = open(sys.argv[1]).read()
rendered = open(sys.argv[2]).read()
assert '  ManifoldKit:\n    path: ManifoldKit\n' in rendered
assert source[source.index('  ManifoldMLX:'):] == rendered[rendered.index('  ManifoldMLX:'):]
PY

EARLY="$TEMP_ROOT/metadata-early/canary-metadata.json"
python3 "$EARLY_METADATA_WRITER" --output "$EARLY" --app-ref main --core-ref main \
    --app-path "$APP" --core-path "$TEMP_ROOT/no-checkout" --reason 'checkout failed'
[[ "$(read_status "$EARLY")" == 'failed' ]] || fail 'early metadata did not fail'
[[ "$(read_commit "$EARLY")" == "$(git -C "$APP" rev-parse HEAD)" ]] || fail 'early metadata lost available app identity'

METADATA="$TEMP_ROOT/metadata-green"
LOG="$TEMP_ROOT/green.log"
CANARY_XCODEGEN="$TOOLS/xcodegen" CANARY_XCODEBUILD="$TOOLS/xcodebuild" CANARY_TEST_LOG="$LOG" \
    bash "$RUNNER" --app-root "$APP" --app-ref main --core-path "$CORE" --core-ref main --metadata-dir "$METADATA"
[[ "$(read_status "$METADATA/canary-metadata.json")" == 'passed' ]] || fail 'green metadata did not pass'
[[ ! -e "$APP/ManifoldKit" && ! -L "$APP/ManifoldKit" ]] || fail 'package identity symlink leaked after success'
[[ ! -e "$APP/.project.core-canary.yml" ]] || fail 'temporary XcodeGen spec leaked after success'
[[ "$(grep -c '^build ' "$LOG")" -eq 2 ]] || fail 'both schemes were not built'
[[ "$(grep -c '^test ' "$LOG")" -eq 2 ]] || fail 'both schemes were not tested'
if grep '^test ' "$LOG" | grep -q 'CODE_SIGNING_ALLOWED=NO'; then
    fail 'UI tests incorrectly disable signing'
fi

MALFORMED="$TEMP_ROOT/metadata-malformed"
assert_failed 'malformed ref' bash "$RUNNER" --app-root "$APP" --core-path "$CORE" --core-ref '../bad' --metadata-dir "$MALFORMED"
[[ "$(read_status "$MALFORMED/canary-metadata.json")" == 'failed' ]] || fail 'malformed ref did not record failure'

LEADING_DASH="$TEMP_ROOT/metadata-leading-dash"
assert_failed 'leading-dash ref' bash "$RUNNER" --app-root="$APP" --core-path="$CORE" --core-ref=--bad --metadata-dir="$LEADING_DASH"
[[ "$(read_status "$LEADING_DASH/canary-metadata.json")" == 'failed' ]] || fail 'leading-dash ref did not record failure'

MISSING="$TEMP_ROOT/metadata-missing"
assert_failed 'missing core checkout' bash "$RUNNER" --app-root "$APP" --core-path "$TEMP_ROOT/missing" --core-ref main --metadata-dir "$MISSING"
[[ "$(read_status "$MISSING/canary-metadata.json")" == 'failed' ]] || fail 'missing input did not record failure'

for checkout in app core; do
    if [[ "$checkout" == app ]]; then
        fail_path="$(cd "$APP" && pwd -P)"
    else
        fail_path="$(cd "$CORE" && pwd -P)"
    fi
    STATUS_FAILURE="$TEMP_ROOT/metadata-status-failure-$checkout"
    STATUS_LOG="$TEMP_ROOT/status-failure-$checkout.log"
    STATUS_MARKER="$TEMP_ROOT/status-injected-$checkout"
    assert_failed "$checkout git status failure" env PATH="$FAKE_GIT:$PATH" \
        CANARY_REAL_GIT="$(command -v git)" CANARY_TEST_STATUS_FAIL_PATH="$fail_path" \
        CANARY_TEST_STATUS_MARKER="$STATUS_MARKER" \
        CANARY_XCODEGEN="$TOOLS/xcodegen" CANARY_XCODEBUILD="$TOOLS/xcodebuild" \
        CANARY_TEST_LOG="$STATUS_LOG" bash "$RUNNER" --app-root "$APP" \
        --core-path "$CORE" --core-ref main --metadata-dir "$STATUS_FAILURE"
    [[ -f "$STATUS_MARKER" ]] || fail "$checkout git status fault was not injected"
    [[ "$(read_status "$STATUS_FAILURE/canary-metadata.json")" == 'failed' ]] \
        || fail "$checkout git status failure did not record failed metadata"
    [[ ! -e "$STATUS_LOG" ]] || fail "$checkout git status failure reached Xcode tools"
done

DIRTY_FILE="$APP/untracked-canary-input"
printf 'dirty\n' > "$DIRTY_FILE"
DIRTY="$TEMP_ROOT/metadata-dirty"
assert_failed 'dirty application checkout' bash "$RUNNER" --app-root "$APP" --core-path "$CORE" --core-ref main --metadata-dir "$DIRTY"
[[ "$(read_status "$DIRTY/canary-metadata.json")" == 'failed' ]] || fail 'dirty checkout did not record failure'
/bin/rm "$DIRTY_FILE"

SHA_MISMATCH="$TEMP_ROOT/metadata-sha-mismatch"
assert_failed 'mismatched core SHA' bash "$RUNNER" --app-root "$APP" --core-path "$CORE" --core-ref main \
    --core-sha 0000000000000000000000000000000000000000 --metadata-dir "$SHA_MISMATCH"
[[ "$(read_status "$SHA_MISMATCH/canary-metadata.json")" == 'failed' ]] || fail 'mismatched SHA did not record failure'

EMPTY_CORE="$TEMP_ROOT/empty-core"
mkdir -p "$EMPTY_CORE"
printf '// no commit\n' > "$EMPTY_CORE/Package.swift"
git -C "$EMPTY_CORE" init -q
EMPTY="$TEMP_ROOT/metadata-empty"
assert_failed 'empty core checkout' bash "$RUNNER" --app-root "$APP" --core-path "$EMPTY_CORE" --core-ref main --metadata-dir "$EMPTY"
[[ "$(read_status "$EMPTY/canary-metadata.json")" == 'failed' ]] || fail 'empty checkout did not record failure'

ln -s "$CORE" "$APP/ManifoldKit"
MISMATCHED="$TEMP_ROOT/metadata-mismatched"
assert_failed 'pre-existing package identity' bash "$RUNNER" --app-root "$APP" --core-path "$CORE" --core-ref main --metadata-dir "$MISMATCHED"
[[ -L "$APP/ManifoldKit" ]] || fail 'pre-existing package identity was changed'
/bin/rm "$APP/ManifoldKit"

BUILD_FAILURE="$TEMP_ROOT/metadata-build-failure"
assert_failed 'build failure' env CANARY_TEST_FAIL_STAGE=build CANARY_XCODEGEN="$TOOLS/xcodegen" CANARY_XCODEBUILD="$TOOLS/xcodebuild" CANARY_TEST_LOG="$TEMP_ROOT/build.log" \
    bash "$RUNNER" --app-root "$APP" --core-path "$CORE" --core-ref main --metadata-dir "$BUILD_FAILURE"
[[ "$(read_status "$BUILD_FAILURE/canary-metadata.json")" == 'failed' ]] || fail 'build failure did not record failure'
[[ ! -e "$APP/ManifoldKit" && ! -L "$APP/ManifoldKit" ]] || fail 'package identity symlink leaked after failure'

TEST_FAILURE="$TEMP_ROOT/metadata-test-failure"
assert_failed 'test failure' env CANARY_TEST_FAIL_STAGE=test CANARY_XCODEGEN="$TOOLS/xcodegen" CANARY_XCODEBUILD="$TOOLS/xcodebuild" CANARY_TEST_LOG="$TEMP_ROOT/test.log" \
    bash "$RUNNER" --app-root "$APP" --core-path "$CORE" --core-ref main --metadata-dir "$TEST_FAILURE"
[[ "$(read_status "$TEST_FAILURE/canary-metadata.json")" == 'failed' ]] || fail 'test failure did not record failure'

CLEANUP_FAILURE="$TEMP_ROOT/metadata-cleanup-failure"
assert_failed 'cleanup failure' env CANARY_TEST_FORCE_CLEANUP_FAILURE=1 CANARY_XCODEGEN="$TOOLS/xcodegen" CANARY_XCODEBUILD="$TOOLS/xcodebuild" CANARY_TEST_LOG="$TEMP_ROOT/cleanup.log" \
    bash "$RUNNER" --app-root="$APP" --core-path="$CORE" --core-ref=main --metadata-dir="$CLEANUP_FAILURE"
[[ "$(read_status "$CLEANUP_FAILURE/canary-metadata.json")" == 'failed' ]] || fail 'cleanup failure recorded a passing status'

cmp -s "$SOURCE_COPY" "$APP/project.yml" || fail 'canary changed the product dependency spec'

echo 'core-canary self-test passed'
