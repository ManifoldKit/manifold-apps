.PHONY: generate build test clean

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
		-destination 'platform=iOS Simulator,name=iPhone 16' \
		CODE_SIGNING_ALLOWED=NO
	xcodebuild build \
		-project Manifold.xcodeproj \
		-scheme ManifoldStudio \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO

test: generate
	xcodebuild test \
		-project Manifold.xcodeproj \
		-scheme Manifold \
		-destination 'platform=iOS Simulator,name=iPhone 16'

clean:
	rm -rf Manifold.xcodeproj DerivedData .build
