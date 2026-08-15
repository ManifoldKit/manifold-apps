#!/bin/bash

set -euo pipefail

# Xcode 27 beta can stop delivering synthesized input after several app
# launches in one UI-test operation. Keep the in-process tests together, but
# give every app-launching test a fresh xcodebuild/XCTest runner. The test
# enumeration below is authoritative: anything not explicitly classified as
# app-launching or Foundation-only is still selected in the in-process shard.

APP_LAUNCHING_TESTS=(
    "ManifoldUITests/AppIntentsUITests/test_coldLaunchEnvelope_isIngestedOnlyAfterModelReadiness"
    "ManifoldUITests/AppIntentsUITests/test_malformedColdLaunchEnvelope_isDiscardedAndReported"
    "ManifoldUITests/AppIntentsUITests/test_registerSetReminder_executesThroughInferenceServiceRegistry"
    "ManifoldUITests/AppIntentsUITests/test_runtimeWiring_reportsSharedRegistryStartupHandlerAndAppGroup"
    "ManifoldUITests/AppIntentsUITests/test_sidebarAppIntentsRow_rendersRealFeatureView"
    "ManifoldUITests/AppIntentsUITests/test_warmInboundURL_routesThroughRootViewIntoLiveChat"
    "ManifoldUITests/CloudUITests/testEmptyStateMessage"
    "ManifoldUITests/CloudUITests/testOpenCloudFeatureShowsAPIConfiguration"
    "ManifoldUITests/CloudUITests/testSavedEndpointAppearsInModelSwitcherAndCanBeSelected"
    "ManifoldUITests/EndpointStoreUITests/testAPIKeyRecoveryCanSaveEndpoint"
    "ManifoldUITests/SmokeUITests/testEmptyStateShowsWelcome"
    "ManifoldUITests/SmokeUITests/testSendMessageFlow"
    "ManifoldUITests/SmokeUITests/testSwitchBetweenSessions"
    "ManifoldUITests/SmokeUITests/testSwitcherChipReachableAndOpensSwitcherOnCompactWidth"
    "ManifoldUITests/ThemingUITests/testSwitchingPresetChangesLivePreview"
    "ManifoldUITests/ToolsUITests/testApprovedWriteToolCompletesAndReturnsResult"
    "ManifoldUITests/ToolsUITests/testCloudBackendAdvertisesFullReferenceCatalog"
)

FOUNDATION_TEST="ManifoldUITests/FoundationDeviceUITests/testFreshInstallLoadsFoundationAndCompletesRealTurn"

write_classified_tests() {
    local output_file="$1"
    printf '%s\n' "${APP_LAUNCHING_TESTS[@]}" "$FOUNDATION_TEST" > "$output_file"
}

validate_enumeration() {
    local actual_file="$1"
    local classified_file="$2"
    local duplicate
    local status=0

    duplicate=$(/usr/bin/sort "$actual_file" | /usr/bin/uniq -d)
    if [[ -n "$duplicate" ]]; then
        echo "device-test: Xcode enumerated duplicate tests:" >&2
        echo "$duplicate" >&2
        status=1
    fi

    duplicate=$(/usr/bin/sort "$classified_file" | /usr/bin/uniq -d)
    if [[ -n "$duplicate" ]]; then
        echo "device-test: duplicate test classifications:" >&2
        echo "$duplicate" >&2
        status=1
    fi

    local test_identifier
    while IFS= read -r test_identifier; do
        if ! /usr/bin/grep -Fqx -- "$test_identifier" "$actual_file"; then
            echo "device-test: classified test was not enumerated: $test_identifier" >&2
            status=1
        fi
    done < "$classified_file"

    return "$status"
}

derive_in_process_tests() {
    local actual_file="$1"
    local classified_file="$2"
    local output_file="$3"
    local grep_status

    grep_status=0
    /usr/bin/grep -Fvx -f "$classified_file" "$actual_file" > "$output_file" || grep_status=$?
    if [[ "$grep_status" -ne 0 && "$grep_status" -ne 1 ]]; then
        return "$grep_status"
    fi
}

self_test() (
    local temp_dir
    temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/manifold-device-gate-self-test.XXXXXX")
    trap 'rm -rf "$temp_dir"' EXIT

    local classified_file="$temp_dir/classified.txt"
    local actual_file="$temp_dir/actual.txt"
    local missing_file="$temp_dir/missing.txt"
    local in_process_file="$temp_dir/in-process.txt"
    local sentinel="ManifoldUITests/SentinelTests/testNewlyDiscoveredTest"

    write_classified_tests "$classified_file"
    printf '%s\n' "$sentinel" > "$actual_file"
    /bin/cat "$classified_file" >> "$actual_file"
    validate_enumeration "$actual_file" "$classified_file"
    derive_in_process_tests "$actual_file" "$classified_file" "$in_process_file"
    /usr/bin/grep -Fqx -- "$sentinel" "$in_process_file"

    /usr/bin/grep -Fvx -- "${APP_LAUNCHING_TESTS[0]}" "$actual_file" > "$missing_file"
    if validate_enumeration "$missing_file" "$classified_file" >/dev/null 2>&1; then
        echo "device-test self-test: missing classified test failed to make validation red" >&2
        return 1
    fi

    echo "device-test self-test passed"
)

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
fi

if [[ "$#" -ne 2 || -z "$1" || -z "$2" ]]; then
    echo "usage: $0 IOS_DEVICE_ID DEVELOPMENT_TEAM" >&2
    exit 2
fi

IOS_DEVICE_ID="$1"
DEVELOPMENT_TEAM="$2"

COMMON_ARGS=(
    -project Manifold.xcodeproj
    -scheme Manifold
    -destination "platform=iOS,id=$IOS_DEVICE_ID"
    -skipPackagePluginValidation
    -allowProvisioningUpdates
    -allowProvisioningDeviceRegistration
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Automatic
)

temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/manifold-device-gate.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
enumeration_json="$temp_dir/tests.json"
actual_tests="$temp_dir/actual.txt"
classified_tests="$temp_dir/classified.txt"
in_process_tests="$temp_dir/in-process.txt"

self_test

echo "device-test: building the signed test products once"
xcodebuild build-for-testing "${COMMON_ARGS[@]}"

echo "device-test: enumerating the exact built test bundle"
xcodebuild test-without-building "${COMMON_ARGS[@]}" \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format json \
    -test-enumeration-output-path "$enumeration_json"

disabled_count=$(/usr/bin/plutil -extract values.0.disabledTests raw -o - "$enumeration_json")
if [[ "$disabled_count" -ne 0 ]]; then
    echo "device-test: disabled tests are not permitted in the release gate" >&2
    exit 1
fi

enabled_count=$(/usr/bin/plutil -extract values.0.enabledTests raw -o - "$enumeration_json")
if [[ "$enabled_count" -eq 0 ]]; then
    echo "device-test: Xcode enumerated no enabled tests" >&2
    exit 1
fi

test_index=0
while [[ "$test_index" -lt "$enabled_count" ]]; do
    identifier=$(/usr/bin/plutil \
        -extract "values.0.enabledTests.$test_index.identifier" \
        raw -o - "$enumeration_json")
    printf '%s\n' "${identifier%\(\)}" >> "$actual_tests"
    test_index=$((test_index + 1))
done

write_classified_tests "$classified_tests"
validate_enumeration "$actual_tests" "$classified_tests"
derive_in_process_tests "$actual_tests" "$classified_tests" "$in_process_tests"

selection_args=()
while IFS= read -r test_identifier; do
    [[ -n "$test_identifier" ]] || continue
    selection_args+=("-only-testing:$test_identifier")
done < "$in_process_tests"

if [[ "${#selection_args[@]}" -gt 0 ]]; then
    echo "device-test: running ${#selection_args[@]} in-process tests"
    xcodebuild test-without-building "${COMMON_ARGS[@]}" "${selection_args[@]}"
fi

for test_identifier in "${APP_LAUNCHING_TESTS[@]}"; do
    echo "device-test: running fresh UI runner for $test_identifier"
    xcodebuild test-without-building "${COMMON_ARGS[@]}" \
        "-only-testing:$test_identifier"
done

echo "device-test: running isolated real Foundation turn"
xcodebuild test-without-building "${COMMON_ARGS[@]}" \
    "-only-testing:$FOUNDATION_TEST"
