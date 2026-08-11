# Known issues

## Draft PRs always show a red `test` / `macos` check

The shared `swift-ci.yml` workflow (ManifoldKit/.github) deliberately fails
fast on draft PRs — a skipped required check would otherwise count as
passing branch protection (the hazard that let manifold-llama#153 merge
unverified). Expected; mark the PR ready for review to get a real verdict.

## ManifoldKit pin floats within `upToNextMinor`

`project.yml` pins ManifoldKit via `minorVersion:` (XcodeGen's
`upToNextMinorVersion`), not an exact version. The generated
`Manifold.xcodeproj` (and any `Package.resolved` it would produce) is
gitignored, so there is nothing to lock the resolved version — a fresh
`xcodegen generate` + build can pick up a newer ManifoldKit patch/minor at
any time. If a build breaks after a ManifoldKit release, check
ManifoldKit's own CHANGELOG.md before assuming a bug in this repo.
