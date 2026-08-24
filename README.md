# manifold-apps

The flagship Manifold reference app for iOS and macOS, built the way a real
adopter would build it: by consuming
[ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) and its companions
from published tags, not local checkouts. ManifoldKit is the product; this app
is executable documentation.

## Manifold (iOS)

The consumer chat app — a single-session `ChatView` wired up with
`ManifoldKit.quickStart()`, targeting iOS 18+.

## Manifold (macOS)

The macOS-native Manifold build, targeting macOS 15+.

## Local inference qualification

The Scenarios sidebar feature runs a curated subset of ManifoldTools' shared
corpus through the app's currently selected backend. It reports tool calls,
assertion verdicts, final output, and elapsed time without creating a second
inference loop. On Apple Silicon, the extended hardware lane exercises that
surface twice against both an MLX model and a GGUF model:

```bash
make mac-real-qualification
```

Override `MANIFOLD_MAC_REAL_MLX_MODEL_PATH` and
`MANIFOLD_MAC_REAL_GGUF_MODEL_PATH` to qualify another same-family pair.

## Building

Both targets consume ManifoldKit by published tag (`upToNextMinor`, see
`project.yml`) — there is no local package checkout or symlink in this repo.

```bash
brew install xcodegen   # once, if you don't already have it
make generate            # xcodegen generate -> Manifold.xcodeproj (gitignored)
make build                # builds both schemes (iOS Simulator + macOS)
make test                 # runs the complete iOS + macOS UI-test targets
make mac-real-qualification # opt-in MLX + GGUF app-level scenario matrix
```

See `AGENTS.md` for the full set of repo-specific conventions and
constraints.

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
