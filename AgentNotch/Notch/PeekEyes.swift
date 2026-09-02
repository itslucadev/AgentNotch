import SwiftUI

/// How a face sits in the panel: where its centre is, how the upright face frame is rotated to
/// get there, and the screen directions expressed in that frame so the sampler can lean into the
/// screen or sag with gravity without knowing which edge it is on.
nonisolated struct PeekPlacement: Equatable {
    var metrics: PeekMetrics
    var center: CGPoint
    var rotation: Angle
    var inward: CGVector
    var down: CGVector
    var bias: CGVector

    /// The round head off the body's start: always upright, resting its gaze on the bar.
    static func head(_ layout: NotchLayout) -> PeekPlacement {
        let rect = layout.headRect
        let inward: CGVector =
            switch layout.edge {
            case .right: CGVector(dx: -1, dy: 0)
            case .left: CGVector(dx: 1, dy: 0)
            case .top: CGVector(dx: 0, dy: 1)
            case .bottom: CGVector(dx: 0, dy: -1)
            }
        // The body lies further along the main axis: below the head on a side edge, beside it on top or bottom.
        let bias = layout.isStacked ? CGVector(dx: 0, dy: 2.5) : CGVector(dx: 2.5, dy: 0)
        return PeekPlacement(
            metrics: .head, center: CGPoint(x: rect.midX, y: rect.midY), rotation: .zero,
            inward: inward, down: CGVector(dx: 0, dy: 1), bias: bias)
    }

    /// Eyes peeking out of the collapsed pill. On a side edge the face lies along the body, so the
    /// pair stacks like someone looking round a door; on top or bottom it sits upright.
    static func pill(_ layout: NotchLayout) -> PeekPlacement {
        let rect = layout.pillRect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        switch layout.edge {
        case .right:
            return PeekPlacement(
                metrics: .pill, center: center, rotation: .degrees(90),
                inward: CGVector(dx: 0, dy: 1), down: CGVector(dx: 1, dy: 0), bias: .zero)
        case .left:
            return PeekPlacement(
                metrics: .pill, center: center, rotation: .degrees(90),
                inward: CGVector(dx: 0, dy: -1), down: CGVector(dx: 1, dy: 0), bias: .zero)
        case .top:
            return PeekPlacement(
                metrics: .pill, center: center, rotation: .zero,
                inward: CGVector(dx: 0, dy: 1), down: CGVector(dx: 0, dy: 1), bias: .zero)
        case .bottom:
            return PeekPlacement(
                metrics: .pill, center: center, rotation: .zero,
                inward: CGVector(dx: 0, dy: -1), down: CGVector(dx: 0, dy: 1), bias: .zero)
        }
    }

    /// Where to look: a hovered ring wins, otherwise the pointer, easing in over the first 80 pt.
    func look(pointer: CGPoint?, target: CGPoint?) -> CGVector? {
        if let target {
            return faceVector(toward: target, magnitude: metrics.reach)
        }
        guard let pointer else { return nil }
        let distance = hypot(pointer.x - center.x, pointer.y - center.y)
        return faceVector(toward: pointer, magnitude: min(1, distance / 80) * metrics.reach)
    }

    /// A panel-space direction from the face centre, rotated back into the face frame.
    private func faceVector(toward point: CGPoint, magnitude: CGFloat) -> CGVector? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let theta = -rotation.radians
        let fx = (dx * cos(theta) - dy * sin(theta)) / length
        let fy = (dx * sin(theta) + dy * cos(theta)) / length
        return CGVector(dx: fx * magnitude, dy: fy * magnitude)
    }
}

/// The eyes and, for the head, the disc they sit in. Nothing here keeps time: the timeline asks
/// the sampler for the frame at its own date, so pausing costs nothing and replaying is exact.
struct PeekView: View {
    enum Style {
        /// Black disc plus eyes, clipped to the disc.
        case head
        /// Eyes only; the caller clips to the pill.
        case pill
    }

    let model: NotchViewModel
    let layout: NotchLayout
    let style: Style
    let paused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let placement = style == .head ? PeekPlacement.head(layout) : PeekPlacement.pill(layout)
        let interval: TimeInterval = style == .head ? 1 / 60 : 1 / 30
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { context in
            let target = style == .head ? model.hoveredIndex.map { layout.ringCenter($0) } : nil
            let face = PeekFace(
                mood: model.mood,
                metrics: placement.metrics,
                inward: placement.inward,
                down: placement.down,
                bias: placement.bias,
                look: placement.look(pointer: model.pointer, target: target),
                rollStart: style == .head ? model.refreshRollStart : nil,
                blinkAt: model.peekBlinkAt,
                reducedMotion: reduceMotion,
                cue: model.peekCue,
                cueStart: model.peekCueStart)
            let frame = face.sample(at: context.date.timeIntervalSinceReferenceDate)
            Canvas { gc, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                if style == .head {
                    let d = NotchMetrics.orbDiameter + frame.swell
                    let disc = Path(ellipseIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
                    gc.fill(disc, with: .color(.black))
                    gc.clip(to: disc)
                }
                gc.translateBy(x: center.x, y: center.y)
                gc.rotate(by: placement.rotation)
                gc.opacity = frame.opacity
                for eye in [frame.left, frame.right] {
                    var eyeContext = gc
                    eyeContext.translateBy(x: eye.center.x, y: eye.center.y)
                    eyeContext.rotate(by: .degrees(eye.tilt))
                    let rect = CGRect(
                        x: -eye.size.width / 2, y: -eye.size.height / 2,
                        width: eye.size.width, height: eye.size.height)
                    let radius = min(eye.size.width, eye.size.height) / 2
                    eyeContext.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(.white))
                }
            }
        }
    }
}
