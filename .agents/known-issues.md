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

## Existing sidebar rows can still be offscreen and non-hittable

On compact iPhones, a lower `NavigationSplitView` sidebar row may satisfy an
XCUITest existence query while remaining outside the visible viewport. Calling
`tap()` on that element does not navigate, so later detail assertions fail and
application-level swipes can misleadingly appear to target the detail while
they are actually scrolling the still-open sidebar. After confirming the
sidebar itself is visible, boundedly scroll until the exact labelled row is
hittable, assert hittability, tap it, and then assert a stable detail element
before continuing. Do not treat `exists` alone as proof that navigation is
possible, and do not fall back to an arbitrary cell.
