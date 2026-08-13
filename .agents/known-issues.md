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

## Feature selection can leave the compact sidebar masking its detail

On compact iPhones, tapping an exact, hittable `NavigationSplitView` sidebar
row can synthesize successfully while the sidebar overlay remains open and the
selected detail stays absent from the accessibility tree. Later detail
assertions then fail, and application-level swipes misleadingly manipulate the
still-open sidebar. Keep exact-row existence and hittability guards (boundedly
scroll first when a lower row is genuinely offscreen), then tap the row and
assert a detail-only element. If it is absent, dismiss the overlay with an
outside-sidebar tap and a swipe-left fallback before the final bounded detail
assertion. Do not infer successful navigation from the row tap alone, and do
not fall back to an arbitrary cell.
