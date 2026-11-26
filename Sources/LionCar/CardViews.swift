import SwiftUI

/// The rounded panel the Car tab's cards and tiles sit on.
extension View {
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Corners.card, style: .continuous))
    }
}

/// A full-width Car tab card: stacked content on the card background.
struct Card<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardBackground()
    }
}

/// A big figure with a small caption under it, for summaries (trips, charging log).
struct StatFigure: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.bold())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "07:05": a schedule time, zero-padded 24-hour.
func clockTime(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
