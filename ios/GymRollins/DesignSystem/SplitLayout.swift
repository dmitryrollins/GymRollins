import SwiftUI

/// Two views side by side, the first taking `leadingFraction` of the width (minus spacing), both as tall as the
/// taller one needs. Unlike a `GeometryReader` with a fixed height, the height follows the content, so buttons with
/// scaled (Dynamic Type) labels or glass-style padding are never clipped.
struct SplitLayout: Layout {
    var leadingFraction: CGFloat = 0.4
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(spacing) { $0 + $1.sizeThatFits(.unspecified).width }
        let widths = columnWidths(total: width, count: subviews.count)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columnWidths(total: bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func columnWidths(total: CGFloat, count: Int) -> [CGFloat] {
        guard count == 2 else { return Array(repeating: total / CGFloat(max(count, 1)), count: count) }
        let available = max(0, total - spacing)
        return [available * leadingFraction, available * (1 - leadingFraction)]
    }
}
