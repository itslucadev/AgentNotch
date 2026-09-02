import CoreGraphics
import Foundation

/// What Peek, the notch's mascot, is feeling. Every case is derived from state the app already
/// models; the face never senses anything on its own. Declared in ascending priority so the
/// loudest mood across providers is simply `max()`.
nonisolated enum PeekMood: Int, Sendable, Comparable, CaseIterable {
    case idle
    /// A live session is working: calm, narrowed, reading.
    case working
    /// Headline window in the critical band: drowsy.
    case critical
    /// Last refresh failed and the reading shown is old.
    case stale
    /// The owning tool is signed out: looks away.
    case needsAuth
    /// The read failed: squint and an occasional shake.
    case failed
    /// Headline window exhausted: asleep until it resets.
    case exhausted
    /// A live session waits for the user. The only mood that moves the body, because it is the
    /// only one that needs attention.
    case waiting

    static func < (lhs: PeekMood, rhs: PeekMood) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The loudest mood one provider justifies.
    init(status: ProviderStatus) {
        switch status {
        case .waiting:
            self = .idle
        case .needsAuth:
            self = .needsAuth
        case .failed:
            self = .failed
        case .ready(let snapshot, let stale):
            var mood = PeekMood.idle
            if snapshot.sessions.contains(where: { $0.activity == .waiting }) {
                mood = .waiting
            } else if snapshot.headline?.band == .exhausted {
                mood = .exhausted
            } else if stale {
                mood = .stale
            } else if snapshot.headline?.band == .critical {
                mood = .critical
            } else if snapshot.sessions.contains(where: { $0.activity == .working }) {
                mood = .working
            }
            self = mood
        }
    }
}

/// Eye sizes for one placement, in points, in the upright face frame (x right, y down, origin at
/// the face centre). `bounds` is the region the eyes must stay inside whatever the mood does.
nonisolated struct PeekMetrics: Sendable, Equatable {
    var eyeSize: CGSize
    var separation: CGFloat
    /// How far the gaze may travel toward a pointer or a hovered ring.
    var reach: CGFloat
    var bounds: CGSize

    /// The round head above the body, the settings orb's twin.
    static let head = PeekMetrics(
        eyeSize: CGSize(width: 7, height: 9.5), separation: 14, reach: 3,
        bounds: CGSize(width: NotchMetrics.orbDiameter, height: NotchMetrics.orbDiameter))
    /// Inside the collapsed pill; ovals, not dots, now that the pill is 25 pt thick.
    static let pill = PeekMetrics(
        eyeSize: CGSize(width: 11, height: 14), separation: 28, reach: 5.3,
        bounds: CGSize(width: NotchMetrics.pillLength, height: NotchMetrics.pillThickness))
}

nonisolated struct PeekEye: Sendable, Equatable {
    var center: CGPoint
    var size: CGSize
    /// Degrees, clockwise, about the eye's centre.
    var tilt: CGFloat
}

/// One rendered instant of the face.
nonisolated struct PeekFrame: Sendable, Equatable {
    var left: PeekEye
    var right: PeekEye
    /// Extra diameter the head gains at this instant: the waiting nudge and the exhausted breath.
    var swell: CGFloat
    var opacity: Double
}

/// One-shot beat Peek plays when a limit window dies or comes back. Distinct from mood: mood is
/// how the face lives; a cue is a short performance on top, then mood resumes.
nonisolated enum PeekCue: Equatable, Sendable, CaseIterable {
    case exhausted
    case reset

    var duration: TimeInterval { 1.55 }

    struct Pose: Sendable {
        var open: CGFloat? = nil
        var lid: CGFloat
        var glance: CGFloat = 0
        var sag: CGFloat = 0
        var swell: CGFloat = 0
        var openMultiplier: CGFloat = 1
    }

    func pose(at u: TimeInterval, reducedMotion: Bool) -> Pose {
        if reducedMotion { return quietPose(at: u) }
        switch self {
        case .exhausted: return Self.exhaustedPose(at: u)
        case .reset: return Self.resetPose(at: u)
        }
    }

    private func quietPose(at u: TimeInterval) -> Pose {
        let lid: CGFloat
        if u < 0.2 {
            let k = CGFloat(u / 0.2)
            lid = abs(k * 2 - 1)
        } else {
            lid = self == .exhausted ? 0.12 : 1
        }
        return Pose(open: self == .exhausted ? 0.12 : 1, lid: lid)
    }

    /// Shock flash, then the lids slam and the gaze sags into sleep.
    private static func exhaustedPose(at u: TimeInterval) -> Pose {
        if u < 0.09 {
            return Pose(open: 1.12, lid: 1, swell: 0.5)
        }
        if u < 0.34 {
            let k = CGFloat(PeekLife.easeInOut((u - 0.09) / 0.25))
            let shake = sin(u * 2 * .pi * 13) * 1.15 * (1 - k)
            return Pose(
                open: 1.12 - k, lid: 1 - 0.9 * k, glance: shake, sag: 1.7 * k, swell: 1.1 * (1 - k))
        }
        let breath = sin(2 * .pi * u / 3.4) * 0.45
        return Pose(open: 0.12, lid: 0.08, sag: 1.8, swell: 0.35 + breath)
    }

    /// Still asleep, then the eyes pop and glance around as the window comes back.
    private static func resetPose(at u: TimeInterval) -> Pose {
        if u < 0.1 {
            return Pose(open: 0.12, lid: 0.12, sag: 1.5)
        }
        if u < 0.4 {
            let k = CGFloat(PeekLife.easeInOut((u - 0.1) / 0.3))
            return Pose(
                open: 0.12 + 0.93 * k, lid: 0.12 + 0.88 * k, sag: 1.5 * (1 - k),
                swell: 4.2 * sin(.pi * k), openMultiplier: 1 + 0.12 * k)
        }
        if u < 1.1 {
            let p = CGFloat((u - 0.4) / 0.7)
            return Pose(
                open: 1.05, lid: 1, glance: sin(p * .pi * 2.4) * 2.1, sag: -0.2,
                swell: 1.1 * (1 - p), openMultiplier: 1.08)
        }
        let p = CGFloat(min((u - 1.1) / 0.45, 1))
        return Pose(open: 1, lid: 1, swell: 0.3 * (1 - p))
    }
}

/// The face sampler: a pure function of time. No clock, no stored animation state, so the same
/// inputs at the same `t` always draw the same frame, which is what the tests lean on.
nonisolated struct PeekFace: Sendable, Equatable {
    var mood: PeekMood
    var metrics: PeekMetrics
    /// Unit vector, in the face frame, pointing from the screen edge into the screen.
    var inward: CGVector
    /// Unit vector, in the face frame, pointing to the bottom of the screen.
    var down: CGVector
    /// Resting gaze offset, e.g. down toward the body for the head.
    var bias: CGVector = .zero
    /// Where to look, in face points; clamped to `metrics.reach`. Nil when nothing is near.
    var look: CGVector? = nil
    /// When a refresh roll started, on the same time base as `sample(at:)`.
    var rollStart: TimeInterval? = nil
    /// A blink forced at this time, on top of the schedule: every shape change hides behind one,
    /// as in the reference video bloub was measured from.
    var blinkAt: TimeInterval? = nil
    /// Drops the nudge, the shake and the roll. Blinking, drift and lids stay: they are the character.
    var reducedMotion = false
    /// One-shot limit notification, sampled the same way as a forced blink.
    var cue: PeekCue? = nil
    var cueStart: TimeInterval? = nil

    static let rollDuration: TimeInterval = 0.75

    func sample(at t: TimeInterval) -> PeekFrame {
        let traits = mood.traits
        let cuePose: PeekCue.Pose? = {
            guard let cue, let cueStart else { return nil }
            let u = t - cueStart
            guard u >= 0, u < cue.duration else { return nil }
            return cue.pose(at: u, reducedMotion: reducedMotion)
        }()

        var lid = traits.blinks ? PeekLife.lid(at: traits.slowBlinks ? t * 0.6 : t) : 1
        if let blinkAt {
            let k = (t - blinkAt) / 0.2
            if k >= 0, k < 1 { lid = min(lid, abs(CGFloat(k) * 2 - 1)) }
        }

        var gaze = CGVector(
            dx: PeekLife.noise(t, period: 7.9, phase: 1.9) * 1.6 * traits.wander,
            dy: PeekLife.noise(t, period: 5.3, phase: 0.3) * 1.0 * traits.wander)
        var swell: CGFloat = 0
        var openMultiplier: CGFloat = 1
        var openBase = traits.open

        if cuePose == nil, let scan = traits.scan {
            gaze.dx += sin(2 * .pi * t / scan.period) * scan.amplitude
        }
        gaze += inward * traits.lean
        gaze += down * traits.sag
        if cuePose == nil, let nudge = traits.nudge, !reducedMotion {
            let phase = t.truncatingRemainder(dividingBy: nudge.every)
            if phase < nudge.duration {
                let k = sin(.pi * phase / nudge.duration)
                swell += nudge.grow * k
                openMultiplier += 0.3 * k
                gaze += inward * (0.8 * k)
            }
        }
        if cuePose == nil, traits.breath > 0 {
            swell += sin(2 * .pi * t / 3.4) * traits.breath
        }
        if cuePose == nil, let shake = traits.shake, !reducedMotion {
            let phase = t.truncatingRemainder(dividingBy: shake.every)
            if phase < shake.duration {
                gaze.dx += sin(t * 2 * .pi * 11) * shake.amplitude * sin(.pi * phase / shake.duration)
            }
        }
        if cuePose == nil, let rollStart, !reducedMotion {
            let phase = t - rollStart
            if phase >= 0, phase < Self.rollDuration {
                let angle = PeekLife.easeInOut(phase / Self.rollDuration) * 2 * .pi - .pi / 2
                let r: CGFloat = 2.2
                gaze.dx += cos(angle) * r
                gaze.dy += sin(angle) * r + r
            }
        }
        if cuePose == nil, let look {
            let length = max(hypot(look.dx, look.dy), 0.0001)
            let clamped = look * (min(length, metrics.reach) / length)
            gaze = gaze * 0.3 + clamped
        }
        if let cuePose {
            lid = cuePose.lid
            if let open = cuePose.open { openBase = open }
            gaze.dx += cuePose.glance
            gaze += down * cuePose.sag
            swell += cuePose.swell
            openMultiplier = cuePose.openMultiplier
        }
        gaze += bias

        func eye(_ index: Int) -> PeekEye {
            let squint = index == 0 ? traits.squint.left : traits.squint.right
            let open = openBase * squint * openMultiplier
            let wide = max(open, 1)
            let narrow = min(open, 1)
            let width = metrics.eyeSize.width * wide
            let height = metrics.eyeSize.height * wide * PeekLife.blinkScale(min(lid, narrow))
            let offset = (CGFloat(index) - 0.5) * metrics.separation
            // Both eyes share one gaze vector, so clamping it keeps the pair an isometry. The
            // extents are those of the tilted rectangle, so a squinting eye stays inside too.
            let radians = traits.tilt * .pi / 180
            let extentX = abs(width / 2 * cos(radians)) + abs(height / 2 * sin(radians))
            let extentY = abs(width / 2 * sin(radians)) + abs(height / 2 * cos(radians))
            let limitX = max(metrics.bounds.width / 2 - abs(offset) - extentX, 0)
            let limitY = max(metrics.bounds.height / 2 - extentY, 0)
            let center = CGPoint(
                x: offset + min(max(gaze.dx, -limitX), limitX),
                y: min(max(gaze.dy, -limitY), limitY))
            return PeekEye(center: center, size: CGSize(width: width, height: height), tilt: traits.tilt)
        }

        return PeekFrame(left: eye(0), right: eye(1), swell: swell, opacity: traits.opacity)
    }
}

// MARK: - Life model

/// Blink schedule and gaze drift, ported from bloub's measured life model: blinks 1.9 to 4.6 s
/// apart with 18 % doubles, 0.18 s each, fast close then slower open, and drift on periods that
/// are prime to one another so it never visibly loops.
nonisolated enum PeekLife {
    static let blinkDuration: TimeInterval = 0.18
    /// The schedule repeats after this long; nobody watches one blink cycle for fifteen minutes.
    static let cycle: TimeInterval = 900

    /// Pre-drawn schedule, deterministic and stateless.
    static let blinks: [TimeInterval] = {
        var seed: UInt32 = 0x5eed
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / 4_294_967_296
        }
        var out: [TimeInterval] = []
        var t = 1.4
        while t < cycle {
            out.append(t)
            t += 1.9 + next() * 2.7
            if next() < 0.18 {
                out.append(t)
                t += 0.24
            }
        }
        return out
    }()

    /// 1 = open, 0 = closed.
    static func lid(at time: TimeInterval) -> CGFloat {
        let t = ((time.truncatingRemainder(dividingBy: cycle)) + cycle).truncatingRemainder(dividingBy: cycle)
        var low = 0
        var high = blinks.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if blinks[mid] <= t {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else { return 1 }
        let k = (t - blinks[found]) / blinkDuration
        guard k <= 1 else { return 1 }
        return CGFloat(k < 0.45 ? 1 - k / 0.45 : (k - 0.45) / 0.55)
    }

    /// Vertical squash applied on top of the lid, never quite zero so a closed eye stays a line.
    static func blinkScale(_ lid: CGFloat) -> CGFloat {
        0.06 + 0.94 * min(max(lid, 0), 1)
    }

    /// Smooth value in -1...1 built from two incommensurate sines.
    static func noise(_ t: TimeInterval, period: Double, phase: Double) -> CGFloat {
        let a = sin(2 * .pi * t / period + phase)
        let b = sin(2 * .pi * t / (period * 0.41) + phase * 2.3)
        return CGFloat(0.62 * a + 0.38 * b)
    }

    static func easeInOut(_ k: Double) -> Double {
        k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
    }
}

// MARK: - Mood traits

nonisolated extension PeekMood {
    struct Traits: Sendable {
        struct Scan: Sendable {
            var amplitude: CGFloat
            var period: Double
        }
        struct Pulse: Sendable {
            var every: Double
            var duration: Double
            var grow: CGFloat = 0
            var amplitude: CGFloat = 0
        }

        /// Lid opening at rest; above 1 the whole eye grows.
        var open: CGFloat = 1
        var wander: CGFloat = 1
        var blinks = true
        var slowBlinks = false
        var scan: Scan? = nil
        /// Gaze pushed into the screen (positive) or toward the edge (negative), in points.
        var lean: CGFloat = 0
        /// Gaze pulled toward the bottom of the screen, in points.
        var sag: CGFloat = 0
        var nudge: Pulse? = nil
        var breath: CGFloat = 0
        var shake: Pulse? = nil
        var squint: (left: CGFloat, right: CGFloat) = (1, 1)
        var tilt: CGFloat = 0
        var opacity: Double = 1
    }

    var traits: Traits {
        switch self {
        case .idle:
            Traits()
        case .working:
            Traits(open: 0.48, wander: 0.25, scan: .init(amplitude: 2.6, period: 1.6))
        case .waiting:
            Traits(open: 1.22, wander: 0.5, lean: 1.4, nudge: .init(every: 3.6, duration: 0.55, grow: 3))
        case .critical:
            Traits(open: 0.6, wander: 0.35, slowBlinks: true, sag: 1.3)
        case .exhausted:
            Traits(open: 0.12, wander: 0, blinks: false, breath: 0.55)
        case .stale:
            Traits(wander: 0.6, squint: (1, 0.42), tilt: 9, opacity: 0.62)
        case .needsAuth:
            Traits(wander: 0.15, lean: -2.4, opacity: 0.72)
        case .failed:
            Traits(
                open: 0.38, wander: 0, blinks: false, shake: .init(every: 4.5, duration: 0.38, amplitude: 1.1),
                opacity: 0.72)
        }
    }
}

// MARK: - Vector arithmetic

extension CGVector {
    nonisolated static func + (lhs: CGVector, rhs: CGVector) -> CGVector {
        CGVector(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
    }
    nonisolated static func += (lhs: inout CGVector, rhs: CGVector) {
        lhs = lhs + rhs
    }
    nonisolated static func * (lhs: CGVector, rhs: CGFloat) -> CGVector {
        CGVector(dx: lhs.dx * rhs, dy: lhs.dy * rhs)
    }
}
