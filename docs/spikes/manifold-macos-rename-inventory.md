# macOS Manifold rename inventory

Status: inventory completed from `origin/main` at `bb34996` (2026-08-19),
then used to implement the confirmed rename in this worktree. The accepted
product direction is that the former macOS `ManifoldStudio` app becomes the
macOS build of flagship `Manifold`; “Studio” is reserved for a future
server/web workbench.

Implementation follow-up: the confirmed mapping is `ManifoldMac`,
`ManifoldMacUITests`, `Mac/`, `MacUITests/`, `MacFeatureRegistry`,
`runsMac*`, `--mac-*`, and `MANIFOLD_MAC_*`. The macOS target deliberately
shares `com.manifoldkit.Manifold` with iOS and starts with fresh local data;
there is no speculative migration or legacy-variable compatibility layer.

## Current shape and exact rename surface

`project.yml` is the source of truth; `Manifold.xcodeproj` is generated and
ignored. It currently declares:

- macOS application target `ManifoldStudio` (`project.yml:67-101`), sourcing
  `Studio/` and `Shared/`, with `PRODUCT_BUNDLE_IDENTIFIER`=
  `com.manifoldkit.ManifoldStudio` (`project.yml:88`).
- macOS UI-test target `ManifoldStudioUITests` (`project.yml:125-137`), sourcing
  `ManifoldStudioUITests/` plus the shared helper
  `ManifoldUITests/UITestHelpers.swift`, depending on `ManifoldStudio`, with
  bundle ID `com.manifoldkit.ManifoldStudioUITests` (`project.yml:135`).
- scheme `ManifoldStudio` (`project.yml:152-169`) building/testing those two
  targets, with five `MANIFOLD_STUDIO_*` environment variables.
- Existing iOS target/scheme `Manifold` and test target `ManifoldUITests` must
  remain distinct in the generated Xcode project (`project.yml:27-65`,
  `103-123`, `139-151`).

The likely mechanical rename set is below. File renames are implementation
work for a follow-up, not part of this inventory:

| Current path | Symbols/strings requiring review |
| --- | --- |
| `Studio/ManifoldStudioApp.swift` | `ManifoldStudioApp`; comments; `storeName: "ManifoldStudio"`; `appName: "Manifold Studio"`; bundle ID literal `com.manifoldkit.ManifoldStudio` |
| `Shared/App/StudioFeatureRegistry.swift` | `StudioFeatureRegistry`; macOS sidebar docs |
| `Shared/App/AppEnvironment.swift` | `ManifoldStudio` docs; `runsStudioRealModelTest`; `runsStudioLocalModelTest`; `studioLocalModelFixtures`; `studioRealModelInfos`; `studioRealDisplayName`; `StudioRealModelDiscoveryError`; fixture names/paths `Studio Fixture MLX/GGUF` and `/tmp/manifold-studio-*`; macOS accessibility-startup comments |
| `Shared/App/RootView.swift` | `ManifoldStudio` docs; `StudioFeatureRegistry.all`; macOS accessibility identifiers and window/chat helper behavior (identifiers are generic and should normally stay stable) |
| `Shared/App/AppFeature.swift` | Doc reference to `StudioFeatureRegistry` |
| `Shared/App/MobileFeatureRegistry.swift` | Doc reference to the macOS registry/product split |
| `Shared/Features/MCP/MCPFeature.swift` | Doc reference to `StudioFeatureRegistry` |
| `Shared/Features/Tools/ManifoldToolset.swift` | “LM Studio” is an unrelated backend identity; do not mechanically rename it |
| `Shared/Support/LaunchArguments.swift` | all `runsStudio*` symbols; flags `--studio-local-model-test` and `--studio-real-model-test`; all five `MANIFOLD_STUDIO_*` keys and docs |
| `ManifoldStudioUITests/StudioLocalModelUITests.swift` | filename, `StudioLocalModelUITests`, fixture labels, failure/accessibility prose, `--studio-local-model-test`; generic IDs such as `chat-model-management-button`, `model-management-tab-picker`, `chat-model-switcher-chip`, `model-switcher-list` are test contracts to preserve unless product wants a new namespace |
| `ManifoldStudioUITests/StudioRealModelUITests.swift` | filename, `StudioRealModelUITests`, all five environment keys, `--studio-real-model-test`, Studio prose and skip message |
| `ManifoldUITests/UITestHelpers.swift` | shared macOS `#if os(macOS)` launch/activation/window and accessibility behavior; helper is not Studio-named but is a dependency of the macOS test target |
| `scripts/test-studio-real-models.sh` | script filename, `MANIFOLD_STUDIO_*` variables, `/private/tmp/manifold-studio-real-models.*`, scheme `ManifoldStudio`, output labels |
| `project.yml` | target, test target, scheme names; macOS bundle IDs; source directory; scheme env keys; target dependencies and archive stanza |
| `Makefile` | `ManifoldStudio` build/test scheme invocations; `studio-real-models` phony target and command; comments describing Studio UI target |
| `.github/workflows/ci.yml` | required `macos` job scheme `ManifoldStudio` at lines 23-29 |
| `README.md` | “Manifold Studio” section and build/test descriptions |
| `CHANGELOG.md` | 0.1.0 macOS bullet |
| `RELEASE.md` | macOS gate wording; currently iOS-only archive/TestFlight instructions should not silently imply a macOS release lane |
| `AGENTS.md` | repository layout, target/test descriptions, and full-gate wording; `CLAUDE.md` is only `@AGENTS.md` and needs no separate edit |

Other files checked and not containing the old product name: `Mobile/`, iOS
entitlements and Info.plist, `Release/TestFlightExportOptions.plist`, all
iOS test source files except the shared `UITestHelpers.swift`, and the package
dependency declarations. Keep iOS bundle ID `com.manifoldkit.Manifold` and
the `manifold://` App Intent URL scheme unchanged unless product explicitly
requests a cross-platform identity change.

## Ordered, conflict-minimizing implementation checklist

1. Resolve product decisions below, especially target/scheme spelling and
   bundle-ID/store migration policy. Record the final mapping before edits.
2. Rename the macOS source directory/file and app entry symbol, then update
   the macOS target's `sources` and bootstrap `storeName`, display `appName`,
   and configuration bundle ID in one coherent change.
3. Rename the macOS test directory/files/classes and launch-argument and
   environment-variable vocabulary. Preserve the generic accessibility IDs
   and shared `UITestHelpers` semantics; update only product-specific labels.
4. Update `project.yml` target/test-target/scheme names and IDs, then
   regenerate the ignored project with `make generate`. Never hand-edit the
   generated project or add a local package path.
5. Update Makefile, macOS CI job, real-model script, AGENTS/README/changelog,
   and release notes in the same PR. Keep the iOS archive/TestFlight lane
   explicitly iOS-only unless a separately approved macOS distribution lane
   is added.
6. Run the complete gates listed below; inspect generated target/scheme names,
   bundle IDs, launch arguments, and accessibility smoke behavior. Do not
   substitute filtered tests for the required full gates.

## Confirmed implementation decisions

- Use `ManifoldMac` for the internal target and scheme and
  `ManifoldMacUITests` for the macOS UI-test target. The built product and
  display name are `Manifold`.
- Use `com.manifoldkit.Manifold` for both platform builds so macOS can join the
  existing cross-platform app identity.
- Treat the old macOS developer data as disposable. The renamed build starts
  fresh; no SwiftData, preferences, Keychain, or App Group migration is added.
- Rename test flags and environment variables atomically to `--mac-*` and
  `MANIFOLD_MAC_*`; do not retain aliases.
- Retain the current macOS Debug-only ad-hoc signing posture. Signing,
  notarization, App Store delivery, and a macOS release lane are deferred.

## Preservation and migration risks

- `AppEnvironment.bootstrap` uses the bundle identifier as part of the app's
  configuration and persistence identity. The shared iOS/macOS value is an
  intentional cross-platform product decision, while the renamed macOS build
  deliberately provides no migration from the old Studio identity.
- `storeName: "ManifoldStudio"` is passed to the ephemeral UI-test store and
  is ignored in the live path; do not infer that renaming this string alone
  migrates production data. Verify the ManifoldKit configuration’s path,
  schema, preferences, Keychain, and any App Group contracts on a real install.
- The macOS target has generated Info.plist only and no entitlements, while
  iOS has `Mobile/Manifold.entitlements` and a registered `manifold` URL
  scheme. Do not copy iOS entitlements or App Intent URL registration into
  macOS without an explicit platform requirement.
- App Store Connect/TestFlight identity is bundle-ID based. `RELEASE.md` and
  `Release/TestFlightExportOptions.plist` currently cover iOS only; a macOS
  rename may be a new product rather than an upgrade and requires signing,
  notarization, distribution, and tester decisions.
- Accessibility IDs are stable cross-platform test contracts. Renaming them
  unnecessarily will make both shared helper behavior and UI tests brittle;
  update only IDs whose product identity is intentionally exposed.
- The real-model gate crosses shell, XCUITest, app launch arguments, scheme
  environment variables, temporary staging paths, and TCC-protected model
  paths. Rename every boundary atomically or the gate silently skips/fails.

## Required build/test/release gates

Exact repository gates (after implementation; not run for this inventory):

```bash
make generate
make build
make test
make device-test IOS_DEVICE_ID='<device-udid>' DEVELOPMENT_TEAM='<team-id>'
make mac-real-models                    # opt-in arm64 Mac + installed models
make testflight-upload IOS_DESTINATION='platform=iOS Simulator,name=<available-simulator>' \
  IOS_DEVICE_ID='<device-udid>' DEVELOPMENT_TEAM='<team-id>'
```

`make build` builds both iOS Simulator and macOS schemes with signing off;
`make test` runs the complete `ManifoldUITests` and macOS UI-test targets and
first runs the device-gate parser self-test. The physical device gate must
run exactly the Foundation test `ManifoldUITests/FoundationDeviceUITests/testIsolatedStoreLoadsFoundationAndCompletesRealTurn`;
do not add simulator tests to that invocation. `make testflight-upload` is the
existing iOS-only release path and reruns `make test`, `make device-test`, and
the signed iOS archive/upload. A future macOS distribution gate must be
specified separately rather than implied by these commands.

## Issue-ready acceptance criteria

- The chosen macOS target, test target, and scheme names are documented and
  no longer claim the reserved future Studio product; generated Xcode metadata
  contains no accidental old target/scheme references.
- Displayed macOS app identity is `Manifold`; the approved bundle-ID and
  upgrade/new-product policy is implemented and documented, with iOS
  `com.manifoldkit.Manifold` behavior unchanged.
- Bootstrap/store/preferences/Keychain/App Group behavior is tested for the
  approved migration policy, including existing-install and fresh-install
  cases; no silent data fork or loss is accepted.
- Normal macOS UI tests pass through the renamed target, and accessibility
  contracts (`chat-model-management-button`, `model-management-tab-picker`,
  `chat-model-switcher-chip`, `model-switcher-list`, chat input/send/assistant
  selectors) remain reachable through `UITestHelpers`.
- Local fixture and opt-in real MLX → GGUF → MLX tests pass with the renamed
  launch arguments/environment variables, or a documented compatibility
  mapping exists for old invocations.
- `make generate`, full `make build`, full `make test`, and all applicable
  release gates pass; CI’s required `test` and `macos` jobs use the approved
  scheme and destination. No filtered test is accepted as the merge gate.
- README, AGENTS, CHANGELOG, release notes, Makefile, CI, scripts, and test
  messages consistently describe macOS Manifold; “Studio” appears only where
  explicitly reserved or in a compatibility/migration note.

## Evidence and self/rework notes

Commands used (read-only):

```bash
git status --short --branch
git rev-parse --show-toplevel
git ls-tree -r --name-only origin/main
rg -n -i 'manifoldstudio|studio|macos|bundle|product|scheme|test' .
rg -l -i 'manifoldstudio|studio' --glob '!docs/**'
nl -ba project.yml; nl -ba Makefile; nl -ba .github/workflows/ci.yml
git log --oneline -8 origin/main
```

The scan was intentionally limited to text/source/config inventory: no
`xcodebuild`, `make build`, `make test`, generated-project edit, source rename,
commit, push, PR, or GitHub mutation was performed. Rework is required if
product input selects a different target/bundle-ID migration policy, if
ManifoldKit’s persistence implementation proves additional identity keys, or
if release owners add a macOS distribution lane.
