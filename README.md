# manifold-apps

Two SwiftUI apps that showcase [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit)
end to end, built the way a real adopter would build them: by consuming the
package from its published tags, not from a local checkout.

## Manifold (iOS)

The consumer chat app — a single-session `ChatView` wired up with
`ManifoldKit.quickStart()`, targeting iOS 18+.

## Manifold Studio (macOS)

The pro showcase app — the macOS-native counterpart, targeting macOS 15+.

## Building

Both targets consume ManifoldKit by published tag (`upToNextMinor`, see
`project.yml`) — there is no local package checkout or symlink in this repo.

```bash
brew install xcodegen   # once, if you don't already have it
make generate            # xcodegen generate -> Manifold.xcodeproj (gitignored)
make build                # builds both schemes (iOS Simulator + macOS)
make test                 # runs the complete iOS + Studio UI-test targets
```

See `AGENTS.md` for the full set of repo-specific conventions and
constraints.

## TestFlight releases

Manifold `0.1.0` is an internal TestFlight release, not a public App Store
launch. The signed archive, upload, physical-device gate, and acceptance
checklist are documented in [`RELEASE.md`](RELEASE.md). A `0.1.0` tag is cut
only after the uploaded build passes that real-device checklist.
