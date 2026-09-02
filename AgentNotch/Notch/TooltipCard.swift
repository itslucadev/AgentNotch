import SwiftUI

nonisolated enum TooltipDirection {
    case pointsRight
    case pointsLeft
    case pointsUp
    case pointsDown
}

/// Black speech bubble beside a ring: limit windows with bars, then live sessions.
struct TooltipCard: View {
    let id: ProviderID
    let status: ProviderStatus
    let direction: TooltipDirection
    /// Where the tail apex sits along the card's notch-facing edge, measured from that edge's start.
    let tailCenter: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch status {
            case .ready(let snapshot, let stale):
                ForEach(snapshot.windows) { window in
                    LimitWindowRow(window: window)
                        .padding(.top, 6)
                }
                if !snapshot.sessions.isEmpty {
                    Divider()
                        .overlay(Color.white.opacity(0.12))
                        .padding(.top, 14)
                    ForEach(snapshot.sessions.prefix(6)) { session in
                        SessionRow(session: session)
                            .padding(.top, 10)
                    }
                }
                if stale {
                    note(
                        "Couldn't read usage; showing the last reading from \(snapshot.fetchedAt, format: .relative(presentation: .named))."
                    )
                }
            case .waiting:
                note("Waiting for the first reading")
            case .needsAuth(let message):
                note(message)
                note(
                    "You stay signed in to the tool that owns the account. Switch accounts in \(id.ownerTool); the notch follows."
                )
            case .failed(let message):
                note(message)
            }
        }
        .padding(NotchMetrics.tooltipPadding)
        .padding(.bottom, 3)
        .frame(width: NotchMetrics.tooltipWidth, alignment: .leading)
        .background {
            TooltipShell(direction: direction, tailCenter: tailCenter)
                .fill(.black)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderGlyph(id: id)
                .frame(width: 16, height: 16)
                .foregroundStyle(.white)
            Text("\(id.displayName) Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            if let plan = status.snapshot?.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private func note(_ text: String) -> some View {
        note(LocalizedStringKey(text))
    }
}

struct LimitWindowRow: View {
    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Text(resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            UsageBar(fraction: window.usedFraction, color: window.band.color)
            Text("\(Int((window.usedFraction * 100).rounded()))% Used")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
        }
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        let minutes = Int(resetsAt.timeIntervalSinceNow / 60)
        if minutes < 1 { return "Resets now" }
        if minutes < 60 { return "Resets in \(minutes) min" }
        return "Resets " + resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(activityColor)
                .frame(width: 6, height: 6)
            Text(session.name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(elapsed)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .monospacedDigit()
        }
    }

    private var activityColor: Color {
        switch session.activity {
        case .working: UsageBand.ample.color
        case .waiting: UsageBand.watch.color
        case .idle: .white.opacity(0.35)
        }
    }

    private var elapsed: String {
        let seconds = Int(-session.startedAt.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }
}

/// Rounded card with a curved tail on the notch side.
struct TooltipShell: Shape {
    var direction: TooltipDirection
    var tailCenter: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = NotchMetrics.tooltipCornerRadius
        let length = NotchMetrics.tooltipTailLength
        let base = NotchMetrics.tooltipTailBase
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

        // Tail geometry along the facing edge: `along` runs along that edge, `out` points away from the card.
        let edgeLength = direction == .pointsRight || direction == .pointsLeft ? rect.height : rect.width
        let apex = min(max(tailCenter, radius + base / 2), edgeLength - radius - base / 2)
        let map: (CGFloat, CGFloat) -> CGPoint
        switch direction {
        case .pointsRight: map = { along, out in CGPoint(x: rect.maxX + out, y: rect.minY + along) }
        case .pointsLeft: map = { along, out in CGPoint(x: rect.minX - out, y: rect.minY + along) }
        case .pointsDown: map = { along, out in CGPoint(x: rect.minX + along, y: rect.maxY + out) }
        case .pointsUp: map = { along, out in CGPoint(x: rect.minX + along, y: rect.minY - out) }
        }

        var tail = Path()
        tail.move(to: map(apex - base / 2, -1))
        tail.addQuadCurve(to: map(apex, length), control: map(apex - base * 0.18, length * 0.55))
        tail.addQuadCurve(to: map(apex + base / 2, -1), control: map(apex + base * 0.18, length * 0.55))
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}
