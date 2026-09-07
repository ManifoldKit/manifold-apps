# Explore native examples

`ExploreFeature` is an optional documentation surface inside Manifold. It is
available alongside Chat for every session state; it does not create a session,
select or load a model, or store onboarding completion.

The Make it yours section renders real `MessageBubbleView` examples. The
Appearance section embeds reusable `ThemingShowcaseContent` from the
standalone `ThemingShowcaseView`, whose `ThemingPreset` updates
the `AppEnvironment.themePreset` consumed by `RootView`'s
`.manifoldTheme(_:)` / `.classicManifoldTheme()` cascade. Resetting appearance
returns the current in-memory selection to Standard; theme persistence across
relaunch is intentionally outside this example.

The Models and Cloud providers controls are routes supplied by `RootView` via
`ExploreNavigationActions`. They open the host's existing
`ModelManagementSheet` and API configuration surface respectively. Explore
does not own a second model registry, endpoint store, inference service, or
credential flow.

## Minimal host wiring

```swift
.environment(
    \.exploreNavigationActions,
    ExploreNavigationActions(
        showModels: { showModelManagement = true },
        showCloud: { selectFeature(CloudFeature.id) }
    )
)
```

The actions remain absent when the host does not inject them, so an unfinished
route is never presented as a tappable control.
