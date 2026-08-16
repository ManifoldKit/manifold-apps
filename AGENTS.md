# manifold-apps — guide for AI coding assistants

Two SwiftUI apps sharing one repo: **Manifold** (iOS 18+, consumer chat) and
**ManifoldStudio** (macOS 15+, pro showcase). Both consume ManifoldKit by
published tag (`https://github.com/ManifoldKit/ManifoldKit`, pinned
`upToNextMinor` from a released version — see `project.yml`). Core
ManifoldKit conventions (bootstrap recipe, sending messages, theming, tool
calling, concurrency rules) live in ManifoldKit's own `AGENTS.md` — this file
covers only what's specific to manifold-apps.

## Layout

- `Mobile/` — the `Manifold` iOS app target (`ManifoldApp.swift`).
- `Studio/` — the `ManifoldStudio` macOS app target (`ManifoldStudioApp.swift`).
- `Shared/` — code shared by both targets: `App/` (the `AppEnvironment`
  composition root, the `AppFeature` protocol seam, `RootView`, per-platform
  feature registries), `Features/` (one stub directory per feature — later
  workers replace only a stub's `install(into:)`/`makeView(env:)`),
  `Support/` (launch-argument parsing, the ported-but-not-yet-wired
  `InboundPayload`/`PendingSharePayload` types), `DesignSystem/` (minimal
  spacing/typography tokens).
- `project.yml` — XcodeGen spec. The generated `Manifold.xcodeproj` is
  **gitignored** (basechat precedent) — regenerate with `make generate`
  whenever `project.yml`, target sources, or dependencies change.

## Build & test

```bash
make generate   # xcodegen generate
make build      # builds both schemes (iOS Simulator + macOS), CODE_SIGNING_ALLOWED=NO
make test       # runs the complete Manifold + ManifoldStudio UI-test targets
make device-test IOS_DEVICE_ID=... DEVELOPMENT_TEAM=... # real Foundation physical gate
make clean      # removes the generated project + build artifacts
```

No `-derivedDataPath` flag — default DerivedData lives outside the repo
deliberately; pointing it in-repo causes a package-resolution wedge (see
ManifoldKit's `scripts/clean-build.sh` history, #2475).

`IOS_DESTINATION` defaults to `iPhone 16` (matches `ci.yml`'s destination)
but is overridable for hosts without that simulator installed (e.g. an
iPhone-17-generation-only Mac): `make test IOS_DESTINATION='platform=iOS
Simulator,name=iPhone 17 Pro'`.

The full UI suite belongs to `make test` and runs on the simulator/macOS. The
physical gate builds signed products once, runs exactly the fresh-install real
Foundation turn, then inspects the xcresult to prove that one required test
passed on the requested iOS device. Do not add simulator-oriented UI tests to
that device invocation: Xcode 27 beta can freeze the iPadOS 27 compositor after
repeated XCTest launches and prevent the device-only evidence from running.

## Constraints specific to this repo

- **Published-tag pins only, floating within `upToNextMinor`.** No
  `.package(path:)`, no local package symlink, no branch/main pin. The
  generated project is gitignored, so there is no `Package.resolved` to lock
  either — pins float on purpose; if you need an unreleased ManifoldKit API,
  report the gap rather than repointing at a branch.
- **Draft PRs show a red `test` / `macos` check by design.** The shared
  `swift-ci.yml` workflow (ManifoldKit/.github) fails drafts fast (a skipped
  required check otherwise counts as passing branch protection — the hazard
  that let manifold-llama#153 merge unverified). Not a bug; mark the PR
  ready to get a real verdict.
- **Never point DerivedData inside this repo.** A local package checkout
  (there is none here) plus an in-repo DerivedData path is what produces the
  "Resolve Package Graph" infinite loop documented across the ManifoldKit
  estate — `make build` deliberately omits `-derivedDataPath` for
  this reason.
- **Generated project is not committed.** `Manifold.xcodeproj/`,
  `DerivedData/`, `.build/`, and `Package.resolved` are all gitignored —
  regenerate locally with `make generate` after any `project.yml` change; CI
  regenerates it fresh on every run.
