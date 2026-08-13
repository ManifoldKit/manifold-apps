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

## Sidebar detection must not accept an arbitrary cell

Feature forms and lists also expose `XCUIElementTypeCell` descendants. A
sidebar helper that falls back to `app.cells.firstMatch` can therefore report
the sidebar as visible while a feature detail is still full-screen, then tap a
form row instead of a chat session. Detect sidebar visibility only from its
title, New Chat button, or a row with the explicit `session-row` identifier;
keep the generic-cell fallback only for lookup after the sidebar is known to
be visible.

## Compact feature navigation must use explicit row actions

On compact iPhones, `List(selection:)` exposes a feature label as a tappable
`StaticText`, but a synthesized tap on a lower row can fail to update the
selection at all. Theming is the fifth iOS feature, while first-row Tools can
still pass, so outside-sidebar taps and swipes cannot repair the failure.
Render iOS Chat/features as full-width plain `Button`s that synchronously set
`selectedFeatureID` and reassert the detail column, with stable
`feature-sidebar-row-<id>` identifiers inside `feature-sidebar-list`. Keep
macOS's native `List(selection:)` + tags. UI tests must target the identified
buttons and scroll only the identified feature list, then assert the app-owned
detail directly.
