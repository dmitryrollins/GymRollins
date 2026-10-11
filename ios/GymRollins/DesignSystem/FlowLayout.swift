import SwiftUI

/// Lays subviews out left to right and wraps onto a new line when the next one doesn't fit, so every chip is always
/// fully on screen (a horizontally scrolling row leaves the last chip half off the edge, where it can't be read or
/// reached — accessibility audit: contrast/clipping on large phones).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measured(subviews, maxWidth: proposal.width ?? .infinity).map(\.size)
        let lines = Self.lines(widths: sizes.map(\.width), maxWidth: proposal.width ?? .infinity, spacing: spacing)
        let height = lines.enumerated().reduce(CGFloat(0)) { total, line in
            total + (line.offset > 0 ? lineSpacing : 0) + (line.element.map { sizes[$0].height }.max() ?? 0)
        }
        let width = lines.map { line in
            line.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(line.count - 1, 0))
        }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let items = measured(subviews, maxWidth: bounds.width)
        let sizes = items.map(\.size)
        var y = bounds.minY
        for line in Self.lines(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing) {
            var x = bounds.minX
            let height = line.map { sizes[$0].height }.max() ?? 0
            for index in line {
                let proposal = items[index].squeezed
                    ? ProposedViewSize(width: bounds.width, height: sizes[index].height) : ProposedViewSize.unspecified
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: proposal)
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
    }

    /// One item as it will be placed: its size and whether it had to be squeezed to the line width.
    private struct Item {
        let size: CGSize
        let squeezed: Bool
    }

    /// Each item's size as placed: its ideal size (an exact fractional width can make a label truncate), or — for an
    /// item wider than a whole line (large Dynamic Type) — its size squeezed to the line, wrapped text included, so the
    /// lines below never overlap it. `squeezed` is kept so placement proposes the same width (the wrapped width may
    /// come back narrower than the line).
    private func measured(_ subviews: Subviews, maxWidth: CGFloat) -> [Item] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return Item(size: ideal, squeezed: false) }
            let squeezed = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            return Item(size: CGSize(width: min(squeezed.width, maxWidth), height: squeezed.height), squeezed: true)
        }
    }

    /// Indices per line: items stay in order, a line breaks before the item that would overflow `maxWidth` (an item
    /// wider than a whole line gets a line of its own).
    static func lines(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > maxWidth {
                lines.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
