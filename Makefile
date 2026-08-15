.PHONY: generate build test release-inputs device-test archive-ios testflight-upload studio-real-models clean

# Overridable so a host with no "iPhone 16" simulator installed (e.g. an
# iPhone-17-generation-only Mac) can still `make build`/`make test` locally:
#   make test IOS_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro'
# Default stays iPhone 16 so CI behavior (ci.yml, which hardcodes the same
# default via the reusable workflow) is unchanged.
IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 16
ARCHIVE_PATH ?= $(CURDIR)/.artifacts/Manifold.xcarchive
EXPORT_OPTIONS_PLIST ?= $(CURDIR)/Release/TestFlightExportOptions.plist

generate:
	xcodegen generate

# No -derivedDataPath: default DerivedData lives outside the repo on purpose.
# An in-repo DerivedData path alongside package resolution causes a
# "Resolve Package Graph" wedge — see ManifoldKit's scripts/clean-build.sh
# history (#2475) for the full writeup.
build: generate
	xcodebuild build \
		-project Manifold.xcodeproj \
		-scheme Manifold \
		-destination '$(IOS_DESTINATION)' \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO
	xcodebuild build \
		-project Manifold.xcodeproj \
		-scheme ManifoldStudio \
		-destination 'platform=macOS' \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO

test: generate
	bash ./scripts/test-ios-device.sh --self-test
	xcodebuild test \
		-project Manifold.xcodeproj \
		-scheme Manifold \
		-destination '$(IOS_DESTINATION)' \
		-skipPackagePluginValidation
	xcodebuild test \
		-project Manifold.xcodeproj \
		-scheme ManifoldStudio \
		-destination 'platform=macOS' \
		-skipPackagePluginValidation

# Physical-device release gate. Pass the device UDID and Apple Developer team:
#   make device-test IOS_DEVICE_ID=... DEVELOPMENT_TEAM=...
release-inputs:
	@test -n '$(IOS_DEVICE_ID)' || (echo 'IOS_DEVICE_ID is required.' >&2; exit 2)
	@test -n '$(DEVELOPMENT_TEAM)' || (echo 'DEVELOPMENT_TEAM is required.' >&2; exit 2)

device-test: generate
	@test -n '$(IOS_DEVICE_ID)' || (echo 'IOS_DEVICE_ID is required.' >&2; exit 2)
	@test -n '$(DEVELOPMENT_TEAM)' || (echo 'DEVELOPMENT_TEAM is required.' >&2; exit 2)
	bash ./scripts/test-ios-device.sh '$(IOS_DEVICE_ID)' '$(DEVELOPMENT_TEAM)'

# Signed archive used for TestFlight. Artifacts stay under the ignored
# .artifacts directory; credentials remain in Xcode/Keychain, never the repo.
archive-ios: generate
	@test -n '$(DEVELOPMENT_TEAM)' || (echo 'DEVELOPMENT_TEAM is required.' >&2; exit 2)
	@mkdir -p '$(dir $(ARCHIVE_PATH))'
	xcodebuild archive \
		-project Manifold.xcodeproj \
		-scheme Manifold \
		-destination 'generic/platform=iOS' \
		-archivePath '$(ARCHIVE_PATH)' \
		-skipPackagePluginValidation \
		-allowProvisioningUpdates \
		DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' \
		CODE_SIGN_STYLE=Automatic

# The supported upload path is deliberately expensive and fail-closed: a
# TestFlight upload must follow both the simulator/macOS suite and signed
# physical-device suite in the same invocation.
testflight-upload: release-inputs test device-test archive-ios
	xcodebuild -exportArchive \
		-archivePath '$(ARCHIVE_PATH)' \
		-exportOptionsPlist '$(EXPORT_OPTIONS_PLIST)' \
		-allowProvisioningUpdates

# Opt-in physical-hardware regression gate. The script validates the machine
# and installed model assets before invoking the complete Studio UI-test target.
studio-real-models:
	bash ./scripts/test-studio-real-models.sh

clean:
	rm -rf Manifold.xcodeproj DerivedData .build .artifacts
