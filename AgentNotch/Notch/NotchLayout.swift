import CoreGraphics

/// Geometry of every notch element for one edge, in panel coordinates with a top-left origin.
/// The body runs along the screen edge; "main" is the along-edge axis and "cross" runs into the screen.
nonisolated struct NotchLayout {
    let edge: NotchEdge
    let cells: Int
    let isExpanded: Bool
    let tooltipHeight: CGFloat

    var isStacked: Bool { edge == .left || edge == .right }
    /// Whether the screen edge sits at the far side of the panel (right / bottom) or at zero (left / top).
    private var edgeAtMax: Bool { edge == .right || edge == .bottom }

    private var thickness: CGFloat { isStacked ? NotchMetrics.thickness : NotchMetrics.barThickness }
    private var bodyLength: CGFloat { NotchMetrics.bodyLength(cells: cells, stacked: isStacked) }
    private var crossExtent: CGFloat { thickness + NotchMetrics.crossMargin }
    private var mainExtent: CGFloat { bodyLength + 2 * NotchMetrics.endMargin }

    var panelSize: CGSize {
        isStacked ? CGSize(width: crossExtent, height: mainExtent) : CGSize(width: mainExtent, height: crossExtent)
    }

    // MARK: Axis helpers

    /// Builds a rect from an along-edge span and a cross span measured from the screen edge inward.
    private func rect(main: ClosedRange<CGFloat>, fromEdge: ClosedRange<CGFloat>) -> CGRect {
        let cross =
            edgeAtMax
            ? (crossExtent - fromEdge.upperBound)...(crossExtent - fromEdge.lowerBound)
            : fromEdge
        return isStacked
            ? CGRect(
                x: cross.lowerBound, y: main.lowerBound, width: cross.upperBound - cross.lowerBound,
                height: main.upperBound - main.lowerBound)
            : CGRect(
                x: main.lowerBound, y: cross.lowerBound, width: main.upperBound - main.lowerBound,
                height: cross.upperBound - cross.lowerBound)
    }

    private func point(main: CGFloat, fromEdge: CGFloat) -> CGPoint {
        let cross = edgeAtMax ? crossExtent - fromEdge : fromEdge
        return isStacked ? CGPoint(x: cross, y: main) : CGPoint(x: main, y: cross)
    }

    /// Along-edge coordinate of a point.
    func main(of point: CGPoint) -> CGFloat { isStacked ? point.y : point.x }

    // MARK: Body

    private var bodyMain: ClosedRange<CGFloat> {
        NotchMetrics.endMargin...(NotchMetrics.endMargin + bodyLength)
    }

    var bodyRect: CGRect { rect(main: bodyMain, fromEdge: 0...thickness) }

    var pillRect: CGRect {
        let mid = (bodyMain.lowerBound + bodyMain.upperBound) / 2
        return rect(
            main: (mid - NotchMetrics.pillLength / 2)...(mid + NotchMetrics.pillLength / 2),
            fromEdge: 0...NotchMetrics.pillThickness
        )
    }

    var cornerRadius: CGFloat { isExpanded ? NotchMetrics.cornerRadius : NotchMetrics.pillCornerRadius }
    var earRadius: CGFloat { isExpanded ? NotchMetrics.earRadius : NotchMetrics.pillEarRadius }

    /// The black shape, including its ears.
    var shapeRect: CGRect {
        let body = isExpanded ? bodyRect : pillRect
        return isStacked
            ? body.insetBy(dx: 0, dy: -earRadius)
            : body.insetBy(dx: -earRadius, dy: 0)
    }

    // MARK: Cells

    private func ringMain(_ index: Int) -> CGFloat {
        if isStacked {
            return bodyMain.lowerBound + NotchMetrics.stackStartInset + NotchMetrics.ringDiameter / 2
                + CGFloat(index) * NotchMetrics.stackPitch
        }
        return bodyMain.lowerBound + NotchMetrics.barEndInset + NotchMetrics.ringDiameter / 2
            + CGFloat(index) * NotchMetrics.barPitch
    }

    func ringCenter(_ index: Int) -> CGPoint {
        if isStacked {
            return point(main: ringMain(index), fromEdge: thickness / 2)
        }
        let body = bodyRect
        return CGPoint(x: ringMain(index), y: body.minY + NotchMetrics.barRingOffset)
    }

    /// Hit area and view frame for a cell: ring plus label, upright.
    func cellRect(_ index: Int) -> CGRect {
        let ring = ringCenter(index)
        let width = isStacked ? thickness : NotchMetrics.barPitch
        return CGRect(
            x: ring.x - width / 2,
            y: ring.y - NotchMetrics.ringDiameter / 2,
            width: width,
            height: NotchMetrics.cellHeight
        )
    }

    // MARK: Settings orb

    var orbRect: CGRect {
        let d = NotchMetrics.orbDiameter
        let start = bodyMain.upperBound + NotchMetrics.orbGap
        return rect(
            main: start...(start + d),
            fromEdge: (NotchMetrics.orbEdgeInset - d / 2)...(NotchMetrics.orbEdgeInset + d / 2)
        )
    }

    var arcCenter: CGPoint {
        point(
            main: bodyMain.upperBound + NotchMetrics.arcDrop + NotchMetrics.arcRadius,
            fromEdge: NotchMetrics.arcEdgeInset
        )
    }

    /// Area that reveals the orb: the arc's bounding box, plus the orb itself once shown.
    func orbHotRect(orbShown: Bool) -> CGRect {
        let reach = NotchMetrics.arcRadius + NotchMetrics.arcLineWidth
        let idle = rect(
            main: (bodyMain.upperBound + 2)...(bodyMain.upperBound + NotchMetrics.arcDrop + reach),
            fromEdge: 0...(NotchMetrics.arcEdgeInset + NotchMetrics.arcLineWidth)
        )
        return orbShown ? idle.union(orbRect) : idle
    }

    // MARK: Peek head

    /// The mascot's head: the settings orb's twin, hung off the body's start instead of its end.
    var headRect: CGRect {
        let d = NotchMetrics.orbDiameter
        let end = bodyMain.lowerBound - NotchMetrics.orbGap
        return rect(
            main: (end - d)...end,
            fromEdge: (NotchMetrics.orbEdgeInset - d / 2)...(NotchMetrics.orbEdgeInset + d / 2)
        )
    }

    // MARK: Tooltip

    var tooltipDirection: TooltipDirection {
        switch edge {
        case .right: .pointsRight
        case .left: .pointsLeft
        case .top: .pointsUp
        case .bottom: .pointsDown
        }
    }

    /// Card rect for the given cell, clamped to the panel.
    func tooltipRect(for index: Int) -> CGRect {
        let ring = ringCenter(index)
        let offset = thickness + NotchMetrics.tooltipGap + NotchMetrics.tooltipTailLength
        let width = NotchMetrics.tooltipWidth
        let height = max(tooltipHeight, 60)
        if isStacked {
            var y = ring.y - height / 2
            y = min(max(y, 8), panelSize.height - height - 8)
            let x = edge == .right ? crossExtent - offset - width : offset
            return CGRect(x: x, y: y, width: width, height: height)
        }
        var x = ring.x - width / 2
        x = min(max(x, 8), panelSize.width - width - 8)
        let y = edge == .bottom ? crossExtent - offset - height : offset
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where the tail apex sits along the card's notch-facing edge.
    func tooltipTailCenter(for index: Int) -> CGFloat {
        let ring = ringCenter(index)
        let card = tooltipRect(for: index)
        return isStacked ? ring.y - card.minY : ring.x - card.minX
    }

    func tooltipHotRect(for index: Int) -> CGRect {
        let card = tooltipRect(for: index)
        let ring = ringCenter(index)
        let tail: CGRect
        switch edge {
        case .right:
            tail = CGRect(
                x: card.maxX, y: ring.y - NotchMetrics.tooltipTailBase / 2, width: NotchMetrics.tooltipTailLength,
                height: NotchMetrics.tooltipTailBase)
        case .left:
            tail = CGRect(
                x: card.minX - NotchMetrics.tooltipTailLength, y: ring.y - NotchMetrics.tooltipTailBase / 2,
                width: NotchMetrics.tooltipTailLength, height: NotchMetrics.tooltipTailBase)
        case .top:
            tail = CGRect(
                x: ring.x - NotchMetrics.tooltipTailBase / 2, y: card.minY - NotchMetrics.tooltipTailLength,
                width: NotchMetrics.tooltipTailBase, height: NotchMetrics.tooltipTailLength)
        case .bottom:
            tail = CGRect(
                x: ring.x - NotchMetrics.tooltipTailBase / 2, y: card.maxY, width: NotchMetrics.tooltipTailBase,
                height: NotchMetrics.tooltipTailLength)
        }
        return card.union(tail)
    }
}
