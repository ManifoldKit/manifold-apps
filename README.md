# manifold-apps

The flagship Manifold reference app for iOS and macOS, built the way a real
adopter would build it: by consuming
[ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) and its companions
from published tags, not local checkouts. ManifoldKit is the product; this app
is executable documentation.

Sample tools are off at launch. Open **Tools → Enable sample tools** to try the
reference tool catalog during the current app session. Turning it off removes
those executors and clears remembered approvals; separately registered
AppIntent tools remain available.

## Manifold (iOS)

The consumer chat app — a single-session `ChatView` wired up with
`ManifoldKit.quickStart()`, targeting iOS 26+.

## Manifold (macOS)

The macOS-native Manifold build, targeting macOS 26+.

Both apps require OS 26 or newer to match the published ManifoldMLX 0.6.2
platform floor. Builds use published release ranges; CI runs on macOS 26 with
Xcode 26.6 and the iOS 26.5 simulator.

## Building

Both targets consume ManifoldKit by published tag (`upToNextMinor`, see
`project.yml`) — there is no local package checkout or symlink in this repo.

```bash
brew install xcodegen   # once, if you don't already have it
make generate            # xcodegen generate -> Manifold.xcodeproj (gitignored)
make build                # builds both schemes (iOS Simulator + macOS)
make test                 # runs the complete iOS + macOS UI-test targets
```

See `AGENTS.md` for the full set of repo-specific conventions and
constraints.

The shared UI suite exercises ChatView's message actions on both platforms.
Regenerate replaces the final assistant reply while retaining its prompt;
editing a user message replaces that prompt, removes every later message, and
generates one replacement downstream reply. The fixture keeps an earlier
completed exchange so the assertions also prove that unrelated history stays
intact.

Run `make mac-real-models` on an Apple silicon Mac to exercise installed
local models. Set `MANIFOLD_MAC_REAL_MLX_MODEL_PATH` to a Gemma 3 MLX model
directory and `MANIFOLD_MAC_REAL_GGUF_MODEL_PATH` to a Llama 3.1 GGUF file for
the Stop and image recall cases. The suite checks local model switching and
whether Gemma can recall an image attached in an earlier turn or in the
stopped turn. The Llama cases check early Stop, preservation of a partial
reply, and sending the next message immediately in the same chat.

For this gate or the macOS portion of `make test`, keep the desktop unlocked
and complete the system's **Enable UI Automation** prompt if it appears. See
[Mac UI test startup troubleshooting](.agents/known-issues.md#mac-ui-test-startup-can-wait-for-authorization)
if XCTest times out before the cases start.

## ManifoldKit compatibility canary

The optional [core compatibility canary](docs/core-canary.md) builds this app
against an exact ManifoldKit checkout while leaving product builds on their
published dependency pins.

## Manifold Studio direction

The planned **Manifold Studio** is a separate SwiftPM server daemon and browser
workbench for advanced ManifoldKit demonstrations, diagnostics, benchmarks,
and presentation of external `manifold-eval` evidence. It is not the macOS app
target and does not own a second inference or evaluation implementation.

See [`docs/plans/manifold-and-studio.md`](docs/plans/manifold-and-studio.md) for
the accepted architecture, spike results, upstream prerequisites, staged
delivery plan, and model-routing retrospective.

## TestFlight releases

Manifold `0.1.0` is an internal TestFlight release, not a public App Store
launch. The signed archive, upload, physical-device gate, and acceptance
checklist are documented in [`RELEASE.md`](RELEASE.md). A `0.1.0` tag is cut
only after the uploaded build passes that real-device checklist.
