#!/bin/bash

set -euo pipefail

# The full UI suite runs in the simulator as part of `make test`. The physical
# gate is deliberately limited to the one capability that a simulator cannot
# prove: an isolated UI-test store selecting Apple Foundation Models through
# the production inference service and completing a real generated turn. Fresh
# production-install behavior is verified separately from the TestFlight build.
#
# Xcode 27 beta on iPadOS 27 beta can leave the device compositor black after
# repeated UI-test launches. Running simulator-oriented tests again on the
# physical device adds no release evidence and can prevent the Foundation test
# from running at all, so this gate launches exactly one XCTest session.

FOUNDATION_TEST="ManifoldUITests/FoundationDeviceUITests/testIsolatedStoreLoadsFoundationAndCompletesRealTurn"
FOUNDATION_TEST_NAME="testIsolatedStoreLoadsFoundationAndCompletesRealTurn()"

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
    local platform="$5"
    local second_test_name="${6:-}"
    local children

    children="{\"name\":\"$test_name\",\"result\":\"$test_result\"}"
    if [[ -n "$second_test_name" ]]; then
        children+=",{\"name\":\"$second_test_name\",\"result\":\"Passed\"}"
    fi

    printf '%s\n' \
        "{\"devices\":[{\"deviceId\":\"$device_id\",\"platform\":\"$platform\"}],\"testNodes\":[{\"children\":[{\"children\":[{\"children\":[$children]}]}]}]}" \
        > "$output_file"
}

assert_fixture_rejected() {
    local fixture="$1"
    local expected_device="$2"
    local description="$3"

    if verify_foundation_result "$fixture" "$expected_device" >/dev/null 2>&1; then
        echo "device-test self-test: $description failed to make validation red" >&2
        return 1
    fi
}

self_test() (
    local temp_dir
    local valid_fixture
    local empty_fixture
    local duplicate_fixture
    local missing_fixture
    local failed_fixture
    local wrong_device_fixture
    local wrong_platform_fixture
    local malformed_fixture
    local expected_device="00008142-SELFTEST"

    temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/manifold-device-gate-self-test.XXXXXX")
    trap 'rm -rf "$temp_dir"' EXIT

    valid_fixture="$temp_dir/valid.json"
    empty_fixture="$temp_dir/empty.json"
    duplicate_fixture="$temp_dir/duplicate.json"
    missing_fixture="$temp_dir/missing.json"
    failed_fixture="$temp_dir/failed.json"
    wrong_device_fixture="$temp_dir/wrong-device.json"
    wrong_platform_fixture="$temp_dir/wrong-platform.json"
    malformed_fixture="$temp_dir/malformed.json"

    write_fixture "$valid_fixture" "$FOUNDATION_TEST_NAME" "Passed" "$expected_device" "iOS"
    verify_foundation_result "$valid_fixture" "$expected_device"

    printf '%s\n' \
        "{\"devices\":[{\"deviceId\":\"$expected_device\",\"platform\":\"iOS\"}],\"testNodes\":[{\"children\":[{\"children\":[{\"children\":[]}]}]}]}" \
        > "$empty_fixture"
    assert_fixture_rejected "$empty_fixture" "$expected_device" "zero-test result"

    write_fixture "$duplicate_fixture" "$FOUNDATION_TEST_NAME" "Passed" "$expected_device" "iOS" "testUnexpectedExtraTest()"
    assert_fixture_rejected "$duplicate_fixture" "$expected_device" "multiple-test result"

    write_fixture "$missing_fixture" "testDifferentTest()" "Passed" "$expected_device" "iOS"
    assert_fixture_rejected "$missing_fixture" "$expected_device" "missing Foundation test"

    write_fixture "$failed_fixture" "$FOUNDATION_TEST_NAME" "Failed" "$expected_device" "iOS"
    assert_fixture_rejected "$failed_fixture" "$expected_device" "failed Foundation result"

    write_fixture "$wrong_device_fixture" "$FOUNDATION_TEST_NAME" "Passed" "00008142-WRONG" "iOS"
    assert_fixture_rejected "$wrong_device_fixture" "$expected_device" "wrong device"

    write_fixture "$wrong_platform_fixture" "$FOUNDATION_TEST_NAME" "Passed" "$expected_device" "iOS Simulator"
    assert_fixture_rejected "$wrong_platform_fixture" "$expected_device" "wrong platform"

    printf '%s\n' '{"devices":[],"testNodes":[]}' > "$malformed_fixture"
    assert_fixture_rejected "$malformed_fixture" "$expected_device" "missing result fields"

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
