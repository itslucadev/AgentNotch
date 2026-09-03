import CoreGraphics

/// Every dimension of the notch, in points. Measured from Codenotch at 2x.
nonisolated enum NotchMetrics {
    /// Body thickness across the screen edge when cells stack along the edge (left / right).
    static let thickness: CGFloat = 70
    /// Body thickness when cells sit side by side (top / bottom): ring plus label plus the same 13pt margins.
    static let barThickness: CGFloat = 97
    static let cornerRadius: CGFloat = 32
    /// Concave fillet where the body meets the screen edge. Same radius as the settings arc.
    static let earRadius: CGFloat = 32

    static let ringDiameter: CGFloat = 44
    static let ringLineWidth: CGFloat = 3
    static let trackLineWidth: CGFloat = 5.5
    static let glyphSize: CGFloat = 17
    static let labelHeight: CGFloat = 17
    /// Ring centre to label centre.
    static let ringToLabel: CGFloat = 41
    static let ringLabelSpacing: CGFloat = ringToLabel - ringDiameter / 2 - labelHeight / 2
    static let cellHeight: CGFloat = ringDiameter + ringLabelSpacing + labelHeight

    /// Stacked layout: ring centres every 102pt, first ring 49pt from the body start, last label 29.5pt from the end.
    static let stackPitch: CGFloat = 102
    static let stackStartInset: CGFloat = 27
    static let stackEndInset: CGFloat = 21
    /// Side by side layout.
    static let barPitch: CGFloat = 84
    static let barEndInset: CGFloat = 20
    /// Ring centre from the bar's top, so the cell stays upright with the label below.
    static let barRingOffset: CGFloat = 35

    /// Collapsed tab: thick enough that Peek's two eyes read as eyes, not a slit of white.
    static let pillThickness: CGFloat = 25
    static let pillLength: CGFloat = 96
    static let pillCornerRadius: CGFloat = 12.5
    static let pillEarRadius: CGFloat = 8

    static let tooltipWidth: CGFloat = 225
    static let tooltipCornerRadius: CGFloat = 15
    static let tooltipPadding: CGFloat = 12
    static let tooltipTailLength: CGFloat = 25
    static let tooltipTailBase: CGFloat = 28
    /// Tail apex to body.
    static let tooltipGap: CGFloat = 15
    /// Tallest card we lay out for; the panel reserves this much beside the body.
    static let tooltipMaxHeight: CGFloat = 280

    static let orbDiameter: CGFloat = 48
    /// Body end to orb start.
    static let orbGap: CGFloat = 12
    /// Orb centre inset from the screen edge.
    static let orbEdgeInset: CGFloat = 37
    static let arcRadius: CGFloat = 32
    static let arcLineWidth: CGFloat = 6
    /// Arc centre inset from the screen edge.
    static let arcEdgeInset: CGFloat = 41.5
    /// Start of the settings arc past the body: same clearance as the mascot, plus the round cap.
    static let arcDrop: CGFloat = orbGap + arcLineWidth / 2

    /// Room kept past both body ends for ears, the orb and tooltips that overhang.
    static let endMargin: CGFloat = 140
    /// Room kept across the edge for the tooltip.
    static let crossMargin: CGFloat = tooltipWidth + tooltipTailLength + tooltipGap + 12

    static func bodyLength(cells: Int, stacked: Bool) -> CGFloat {
        let count = max(cells, 1)
        if stacked {
            return stackStartInset + ringDiameter / 2 + CGFloat(count - 1) * stackPitch + ringToLabel + labelHeight / 2
                + stackEndInset
        }
        return 2 * barEndInset + ringDiameter + CGFloat(count - 1) * barPitch
    }
}
