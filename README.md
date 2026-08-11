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
make test                  # FAILS until PR2 adds ManifoldUITests (deliberate — no silent no-op gate)
```

See `AGENTS.md` for the full set of repo-specific conventions and
constraints.
