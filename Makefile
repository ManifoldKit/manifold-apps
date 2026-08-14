.PHONY: generate build test clean

# Overridable so a host with no "iPhone 16" simulator installed (e.g. an
# iPhone-17-generation-only Mac) can still `make build`/`make test` locally:
#   make test IOS_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro'
# Default stays iPhone 16 so CI behavior (ci.yml, which hardcodes the same
# default via the reusable workflow) is unchanged.
IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 16

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

clean:
	rm -rf Manifold.xcodeproj DerivedData .build
