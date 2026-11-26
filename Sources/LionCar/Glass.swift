import SwiftUI

// Liquid Glass (iOS 26 and later) for the controls that float above the content — buttons, the map's pills, the
// toast — following Apple's guidance to keep glass for controls and leave content (cards, lists) solid.
// On iOS 17–25 each helper falls back to exactly what the app drew before.

extension View {
    /// The main action of a card or screen (Lock, Charge now…): tinted glass.
    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// A secondary action (Lights, Horn, Update now…): clear glass.
    @ViewBuilder func glassButton() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    /// A small floating label (map status, toast) on glass. Regular glass, not clear: text must stay readable on a map.
    @ViewBuilder func glassPill() -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: Capsule()) } else { background(.regularMaterial, in: Capsule()) }
    }

    /// The tab bar shrinks while scrolling down, as in Apple's own apps.
    @ViewBuilder func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }
}

/// Glass shapes that sit next to each other (Lock / Unlock, the map's pills) blend and move together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Corner radii for the solid content panels, rounder to match iOS 26's grouped sections.
enum Corners {
    static let card: CGFloat = 24
    static let banner: CGFloat = 18
}
