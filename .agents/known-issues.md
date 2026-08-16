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

## Feature navigation needs different compact and regular-width semantics

On a compact iPhone 16, the sidebar's sibling `SessionListView` and feature
`List` can report a lower feature button as existing and hittable, synthesize
its tap, yet never run the button action. First-row Tools still passes while
fifth-row Theming fails, and an artificial pre-tap list scroll makes Theming
pass, proving the stacked-list hit-routing/position is causal rather than the
detail transition. Render the iOS feature region as a `ScrollView` with a
`LazyVStack` of full-width plain `Button`s that synchronously select the
feature and reassert the detail column on compact widths. On regular-width
iPad, keep a native `List(selection:)`: replacing it with those explicit
buttons puts the visible feature rows below NavigationSplitView's detail
hit-testing layer, so taps synthesize without changing selection. Keep stable
`feature-sidebar-row-<id>` identifiers inside `feature-sidebar-list` on both
paths. UI tests must query identified descendants without constraining the
element type (iPad exposes the native row as a cell/combined label, not a
button), use a center-coordinate tap only when the native row reports a real
frame but `isHittable == false`, and assert the app-owned detail directly.

## Xcode 27 beta can leave physical-device UI automation on a black screen

On an iPad running iOS 27 beta, Xcode 27 beta UI tests can still install and
launch Manifold and expose its complete accessibility hierarchy while every
synthesized tap or text-entry event is ignored. Both XCTest screen recordings
and `devicectl device capture screenshot` are black (sometimes with a spinner),
even though `devicectl` reports the device connected, paired, unlocked,
Developer Mode enabled, and the backlight active. Restarting CoreDeviceService
restores enumeration but not display capture or input. A full-suite retry after
a reboot can pass its first app launch and then degrade again on later launches;
an isolated test can pass immediately beforehand. Fresh `xcodebuild` processes
do not reset the device-side XCTest/compositor state, and terminating
`testmanagerd` or `AutomationModeUI` does not recover the display. The release
gate therefore keeps the complete simulator/macOS suite in `make test` and
runs exactly one physical XCTest session: fresh install → real Foundation
model load → generated reply. It inspects the xcresult so a missing, skipped,
zero-test, wrong-device, or failed result cannot pass. Treat simultaneous black
capture + a still-running app as a device-runner failure, not an app-layout
verdict; reboot and unlock the iPad before rerunning the isolated device gate.
TestFlight acceptance remains a separate manual real-device gate.

## Ad-hoc simulator UI tests cannot prove App Group sharing cross-process

Xcode can correctly generate `CODE_SIGN_ENTITLEMENTS` and a
`*-Simulated.xcent` containing `com.apple.security.application-groups` while
the locally ad-hoc-signed simulator app / UI-test runner still expose empty
signed entitlements. In that configuration, `UserDefaults(suiteName:)` from
the runner does not seed the app process's suite, even when both targets name
the same group. Verify production configuration from the generated iPhoneOS
build settings and entitlement intermediate; exercise the store/read/buffer
logic in-process on the simulator, and do not describe that test as
cross-process App Group proof.

## Studio real-model UI tests must stage models outside Documents and await a terminal turn

A macOS XCUITest app can remain on its loading screen while the main actor is
blocked in `NSURLDirectoryEnumerator` / `__open` against the maintainer's
Documents model library, even though the same files are readable from the
shell. Stage clone-on-write copies under a uniquely named `/private/tmp`
directory, pass their validated byte sizes across the XCTest launch boundary,
and let the companion backend perform the authoritative format check when the
model is selected. Also do not treat the first non-empty assistant accessibility
node as turn completion: a tool-call placeholder can appear while generation
is still waiting for approval. The real gate must observe `Stop generation`
appear and then disappear, and fail if the approval sheet appears before that
terminal state. A missing `xcrun --find metallib` result is not an app-build
preflight; Xcode's package plugins can still compile and bundle the required
Metal libraries, so the real load is the authoritative check.

## macOS can move the model-switcher toolbar chip into More overflow

On a hosted arm64 runner, `chat-model-switcher-chip` can exist in the
accessibility tree but remain non-hittable for the full wait because macOS has
collapsed the principal toolbar item into the system `More` overflow. A bounded
existence-and-hittability wait still handles transient launch settling; if the
chip remains unavailable, open the real `More` toolbar button and select the
same accessibility-identified chip from its menu hierarchy. Do not resize the
window, tap coordinates, or add a navigation repair that bypasses the user path.
After selection, macOS may expose nested buttons with that same identifier: the
outer button carries the active model label while its child is labelled
`Switch model`. Assertions about the active model must filter the identified
query by the expected label before taking `firstMatch`; a keyed single-element
lookup fails when both accessibility nodes are present.

## macOS UI tests can launch with no window or leave the host app frontmost

The GUI process that launched `xcodebuild` can remain frontmost after the test
app launches, leaving its controls disabled and non-hittable. Calling
`XCUIApplication.activate()` is not a repair: under the full gate it can block
for about a minute and throw while the app stays `Running Background`. A prior
test can also persist an intentional all-windows-closed state, leaving only the
app menu bar after relaunch. Launch with `-ApplePersistenceIgnoreState YES`,
send Command-N when no app window appears, then tap an inert point in the tested
window's title region and assert foreground state before interacting with
controls. In ManifoldStudio, normalized x=0.3 is the title; x=0.5 hits the
model-switcher chip and opens its popover, so a generic title-center click
introduces a different test failure.
