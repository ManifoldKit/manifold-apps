import SwiftUI

/// Minimal spacing/typography tokens for chrome `RootView` and feature stubs
/// own directly (session list, feature nav, empty states). Deliberately
/// small — most visual styling flows through `ManifoldTheme`
/// (`.manifoldTheme(_:)`, applied once in `RootView`); grow this only when a
/// real feature needs a token that isn't here yet, not speculatively.
enum DesignSystem {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Typography {
        static let title = Font.title2.weight(.semibold)
        static let body = Font.body
        static let caption = Font.caption
    }
}
