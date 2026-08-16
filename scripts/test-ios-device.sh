#!/bin/bash

set -euo pipefail

# The full UI suite runs in the simulator as part of `make test`. The physical
# gate is deliberately limited to the one capability that a simulator cannot
# prove: a fresh install selecting Apple Foundation Models and completing a
# real generated turn.
#
# Xcode 27 beta on iPadOS 27 beta can leave the device compositor black after
# repeated UI-test launches. Running simulator-oriented tests again on the
# physical device adds no release evidence and can prevent the Foundation test
# from running at all, so this gate launches exactly one XCTest session.

FOUNDATION_TEST="ManifoldUITests/FoundationDeviceUITests/testFreshInstallLoadsFoundationAndCompletesRealTurn"
FOUNDATION_TEST_NAME="testFreshInstallLoadsFoundationAndCompletesRealTurn()"

extract_result_value() {
    local result_json="$1"
    local key_path="$2"
    local value

    if ! value=$(/usr/bin/plutil -extract "$key_path" raw -o - "$result_json" 2>/dev/null); then
        echo "device-test: result bundle is missing $key_path" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

verify_foundation_result() {
    local result_json="$1"
    local expected_device_id="$2"
    local test_count
    local test_name
    local test_result
    local device_id
    local platform

    test_count=$(extract_result_value \
        "$result_json" \
        "testNodes.0.children.0.children.0.children")
    if [[ "$test_count" -ne 1 ]]; then
        echo "device-test: expected exactly one physical Foundation test, found $test_count" >&2
        return 1
    fi

    test_name=$(extract_result_value \
        "$result_json" \
        "testNodes.0.children.0.children.0.children.0.name")
    if [[ "$test_name" != "$FOUNDATION_TEST_NAME" ]]; then
        echo "device-test: required Foundation test did not execute (found: $test_name)" >&2
        return 1
    fi

    test_result=$(extract_result_value \
        "$result_json" \
        "testNodes.0.children.0.children.0.children.0.result")
    if [[ "$test_result" != "Passed" ]]; then
        echo "device-test: Foundation test result was $test_result" >&2
        return 1
    fi

    device_id=$(extract_result_value "$result_json" "devices.0.deviceId")
    if [[ "$device_id" != "$expected_device_id" ]]; then
        echo "device-test: result came from unexpected device $device_id" >&2
        return 1
    fi

    platform=$(extract_result_value "$result_json" "devices.0.platform")
    if [[ "$platform" != "iOS" ]]; then
        echo "device-test: result came from unexpected platform $platform" >&2
        return 1
    fi
}

write_fixture() {
    local output_file="$1"
    local test_name="$2"
    local test_result="$3"
    local device_id="$4"

    printf '%s\n' \
        "{\"devices\":[{\"deviceId\":\"$device_id\",\"platform\":\"iOS\"}],\"testNodes\":[{\"children\":[{\"children\":[{\"children\":[{\"name\":\"$test_name\",\"result\":\"$test_result\"}]}]}]}]}" \
        > "$output_file"
}

self_test() (
    local temp_dir
    local valid_fixture
    local missing_fixture
    local failed_fixture
    local expected_device="00008142-SELFTEST"

    temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/manifold-device-gate-self-test.XXXXXX")
    trap 'rm -rf "$temp_dir"' EXIT

    valid_fixture="$temp_dir/valid.json"
    missing_fixture="$temp_dir/missing.json"
    failed_fixture="$temp_dir/failed.json"

    write_fixture "$valid_fixture" "$FOUNDATION_TEST_NAME" "Passed" "$expected_device"
    verify_foundation_result "$valid_fixture" "$expected_device"

    write_fixture "$missing_fixture" "testDifferentTest()" "Passed" "$expected_device"
    if verify_foundation_result "$missing_fixture" "$expected_device" >/dev/null 2>&1; then
        echo "device-test self-test: missing Foundation test failed to make validation red" >&2
        return 1
    fi

    write_fixture "$failed_fixture" "$FOUNDATION_TEST_NAME" "Failed" "$expected_device"
    if verify_foundation_result "$failed_fixture" "$expected_device" >/dev/null 2>&1; then
        echo "device-test self-test: failed Foundation result failed to make validation red" >&2
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
result_bundle="$temp_dir/FoundationDevice.xcresult"
result_json="$temp_dir/FoundationDevice.json"

self_test

echo "device-test: building the signed test products once"
xcodebuild build-for-testing "${COMMON_ARGS[@]}"

echo "device-test: running one isolated real Foundation turn"
xcodebuild test-without-building "${COMMON_ARGS[@]}" \
    "-only-testing:$FOUNDATION_TEST" \
    -resultBundlePath "$result_bundle"

xcrun xcresulttool get test-results tests \
    --path "$result_bundle" \
    --compact \
    > "$result_json"

verify_foundation_result "$result_json" "$IOS_DEVICE_ID"
echo "device-test: verified one passed real Foundation turn on $IOS_DEVICE_ID"
