import SwiftUI

/// Placeholder body for a feature stub — swapped for a real view once the
/// feature is ported. A later worker replaces only the owning feature's
/// `makeView(env:)`; this view itself should not need to change.
struct NotYetPortedView: View {
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "hammer")
        } description: {
            Text("\(title) hasn't been ported to manifold-apps yet.")
        }
    }
}
