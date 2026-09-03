import CoreGraphics
import Foundation
import Testing

@testable import AgentNotch

struct PeekFaceTests {
    private static let headFace = PeekFace(
        mood: .idle, metrics: .head, inward: CGVector(dx: -1, dy: 0), down: CGVector(dx: 0, dy: 1),
        bias: CGVector(dx: 0, dy: 2.5))
    private static let pillFace = PeekFace(
        mood: .idle, metrics: .pill, inward: CGVector(dx: 0, dy: 1), down: CGVector(dx: 1, dy: 0))

    private static let looks: [CGVector?] =
        [nil]
        + (0..<8).map { i in
            let a = Double(i) / 8 * 2 * .pi
            return CGVector(dx: cos(a) * 10, dy: sin(a) * 10)
        }

    private static func corners(_ eye: PeekEye) -> [CGPoint] {
        let r = eye.tilt * .pi / 180
        let hw = eye.size.width / 2
        let hh = eye.size.height / 2
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { x, y in
            CGPoint(x: eye.center.x + x * cos(r) - y * sin(r), y: eye.center.y + x * sin(r) + y * cos(r))
        }
    }

    @Test func sampleIsAPureFunctionOfTime() {
        let face = Self.headFace
        let a = face.sample(at: 12.34)
        _ = face.sample(at: 99)
        _ = face.sample(at: 0.5)
        #expect(face.sample(at: 12.34) == a)
    }

    @Test(arguments: PeekMood.allCases)
    func headEyesStayInsideTheDisc(mood: PeekMood) {
        let radius = NotchMetrics.orbDiameter / 2
        for look in Self.looks {
            var face = Self.headFace
            face.mood = mood
            face.look = look
            face.rollStart = 5
            for step in 0..<(60 * 30) {
                let frame = face.sample(at: Double(step) / 30)
                for eye in [frame.left, frame.right] {
                    for corner in Self.corners(eye) {
                        #expect(
                            hypot(corner.x, corner.y) <= radius,
                            "\(mood) t=\(Double(step) / 30) look=\(String(describing: look))")
                    }
                }
            }
        }
    }

    @Test(arguments: PeekMood.allCases)
    func pillEyesStayInsideThePill(mood: PeekMood) {
        let halfLength = NotchMetrics.pillLength / 2
        let halfThickness = NotchMetrics.pillThickness / 2
        for look in Self.looks {
            var face = Self.pillFace
            face.mood = mood
            face.look = look
            for step in 0..<(60 * 30) {
                let frame = face.sample(at: Double(step) / 30)
                for eye in [frame.left, frame.right] {
                    for corner in Self.corners(eye) {
                        #expect(abs(corner.x) <= halfLength + 0.01)
                        #expect(abs(corner.y) <= halfThickness + 0.01, "\(mood) t=\(Double(step) / 30)")
                    }
                }
            }
        }
    }

    @Test func bothEyesMoveTogether() {
        var face = Self.headFace
        face.look = CGVector(dx: 3, dy: -2)
        for step in 0..<600 {
            let frame = face.sample(at: Double(step) / 20)
            #expect(abs(frame.right.center.x - frame.left.center.x - PeekMetrics.head.separation) < 0.001)
            #expect(abs(frame.right.center.y - frame.left.center.y) < 0.001)
        }
    }

    @Test func idleBlinksOnTheMeasuredSchedule() {
        let face = Self.headFace
        let open = PeekMetrics.head.eyeSize.height
        // First blink starts at 1.4 s and closes fastest 45 % of the way through 0.18 s.
        let closed = face.sample(at: 1.4 + 0.18 * 0.45).left.size.height
        #expect(closed < open * 0.1)
        #expect(face.sample(at: 1.0).left.size.height > open * 0.95)
        #expect(face.sample(at: 1.4 + 0.18 * 0.45 + PeekLife.cycle).left.size.height < open * 0.1)
    }

    @Test func forcedBlinkClosesTheLid() {
        var face = Self.headFace
        face.blinkAt = 40
        let open = PeekMetrics.head.eyeSize.height
        #expect(face.sample(at: 40.1).left.size.height < open * 0.1)
        #expect(face.sample(at: 39.9).left.size.height > open * 0.9)
    }

    @Test func moodsReadAsIntended() {
        let idle = Self.headFace.sample(at: 30)
        var waiting = Self.headFace
        waiting.mood = .waiting
        var exhausted = Self.headFace
        exhausted.mood = .exhausted
        var working = Self.headFace
        working.mood = .working

        #expect(waiting.sample(at: 30).left.size.height > idle.left.size.height)
        #expect(working.sample(at: 30).left.size.height < idle.left.size.height * 0.6)
        for step in 0..<300 {
            let eye = exhausted.sample(at: Double(step) / 10).left
            #expect(eye.size.height < PeekMetrics.head.eyeSize.height * 0.2)
        }
    }

    @Test func reducedMotionKeepsTheLidsAndDropsTheNudge() {
        var face = Self.headFace
        face.mood = .waiting
        var still = face
        still.reducedMotion = true
        let idle = Self.headFace
        var moved = false
        var swelled = false
        for step in 0..<200 {
            let t = Double(step) / 40
            let frame = face.sample(at: t)
            let quiet = still.sample(at: t)
            if frame.swell > 0.5 { swelled = true }
            if quiet.swell != 0 { moved = true }
            // Blinks are kept, so compare against idle on the same schedule: still wider at every instant.
            #expect(
                quiet.left.size.height > idle.sample(at: t).left.size.height * 1.1, "waiting still reads as wide eyes")
        }
        #expect(swelled)
        #expect(!moved)
    }

    @Test func moodPriorityAcrossProviders() {
        let now = Date()
        func snapshot(fraction: Double, sessions: [AgentSession.Activity] = []) -> ProviderSnapshot {
            ProviderSnapshot(
                id: .claude, account: nil, plan: nil,
                windows: [LimitWindow(id: "w", label: "w", usedFraction: fraction, resetsAt: nil)],
                sessions: sessions.enumerated().map {
                    AgentSession(id: "\($0.offset)", name: "s", detail: "", activity: $0.element, startedAt: now)
                },
                fetchedAt: now)
        }
        #expect(PeekMood(status: .waiting) == .idle)
        #expect(PeekMood(status: .ready(snapshot(fraction: 0.2), stale: false)) == .idle)
        #expect(
            PeekMood(status: .ready(snapshot(fraction: 0.2, sessions: [.idle, .working]), stale: false)) == .working)
        #expect(PeekMood(status: .ready(snapshot(fraction: 0.8), stale: false)) == .critical)
        #expect(PeekMood(status: .ready(snapshot(fraction: 0.8), stale: true)) == .stale)
        #expect(PeekMood(status: .ready(snapshot(fraction: 1.2), stale: true)) == .exhausted)
        #expect(PeekMood(status: .ready(snapshot(fraction: 1.2, sessions: [.waiting]), stale: false)) == .waiting)
        #expect(PeekMood(status: .needsAuth("x")) == .needsAuth)
        #expect(PeekMood(status: .failed("x")) == .failed)

        let across: [PeekMood] = [
            PeekMood(status: .ready(snapshot(fraction: 1.2), stale: false)),
            PeekMood(status: .ready(snapshot(fraction: 0.1, sessions: [.waiting]), stale: false)),
            PeekMood(status: .failed("x")),
        ]
        #expect(across.max() == .waiting)
    }

    @Test func exhaustedCueSlamsTheLids() {
        var face = Self.headFace
        face.cue = .exhausted
        face.cueStart = 10
        let open = PeekMetrics.head.eyeSize.height
        let flash = face.sample(at: 10.04)
        #expect(flash.left.size.height > open * 0.9)
        let slam = face.sample(at: 10.28)
        #expect(slam.left.size.height < open * 0.25)
        #expect(slam.left.size.height < flash.left.size.height)
    }

    @Test func resetCuePopsTheEyesOpen() {
        var face = Self.headFace
        face.cue = .reset
        face.cueStart = 10
        let asleep = face.sample(at: 10.04)
        let wake = face.sample(at: 10.25)
        #expect(asleep.left.size.height < PeekMetrics.head.eyeSize.height * 0.3)
        #expect(wake.left.size.height > asleep.left.size.height * 2)
        #expect(wake.swell > 1)
    }

    @Test func cueEndsAndMoodResumes() {
        var cued = Self.headFace
        cued.cue = .exhausted
        cued.cueStart = 10
        let idle = Self.headFace.sample(at: 12)
        #expect(cued.sample(at: 12) == idle)
    }

    @Test(arguments: PeekCue.allCases)
    func cueEyesStayInsideTheDisc(cue: PeekCue) {
        let radius = NotchMetrics.orbDiameter / 2
        var face = Self.headFace
        face.cue = cue
        face.cueStart = 0
        for step in 0...Int(cue.duration * 60) {
            let frame = face.sample(at: Double(step) / 60)
            for eye in [frame.left, frame.right] {
                for corner in Self.corners(eye) {
                    #expect(hypot(corner.x, corner.y) <= radius, "\(cue) t=\(Double(step) / 60)")
                }
            }
        }
    }

    @Test func reducedMotionCueDropsTheSlamAndBounce() {
        var loud = Self.headFace
        loud.cue = .exhausted
        loud.cueStart = 5
        var quiet = loud
        quiet.reducedMotion = true
        var shook = false
        for step in 0..<40 {
            let t = 5 + Double(step) / 60
            if abs(loud.sample(at: t).left.center.x - quiet.sample(at: t).left.center.x) > 0.4 {
                shook = true
            }
        }
        #expect(shook)
        #expect(quiet.sample(at: 5.25).swell == 0)

        var reset = Self.headFace
        reset.cue = .reset
        reset.cueStart = 5
        reset.reducedMotion = true
        var bounced = false
        for step in 0..<40 {
            if reset.sample(at: 5 + Double(step) / 60).swell > 0.5 { bounced = true }
        }
        #expect(!bounced)
    }

    @Test func moodChangesPickTheirCue() {
        #expect(PeekCue.onMoodChange(from: .idle, to: .waiting) == .hey)
        #expect(PeekCue.onMoodChange(from: .working, to: .waiting) == .hey)
        #expect(PeekCue.onMoodChange(from: .working, to: .idle) == .phew)
        #expect(PeekCue.onMoodChange(from: .idle, to: .critical) == .uhOh)
        #expect(PeekCue.onMoodChange(from: .idle, to: .needsAuth) == .lookAway)
        #expect(PeekCue.onMoodChange(from: .critical, to: .idle) == nil)
        #expect(PeekCue.onMoodChange(from: .waiting, to: .waiting) == nil)
        // Limit notifications own the sleep and the wake-up; a mood change never doubles them.
        #expect(PeekCue.onMoodChange(from: .idle, to: .exhausted) == nil)
        #expect(PeekCue.onMoodChange(from: .exhausted, to: .waiting) == nil)
    }

    @Test(arguments: [PeekCue.hey, .phew, .uhOh, .lookAway, .boop])
    func cueHandsBackNeutral(cue: PeekCue) {
        for reduced in [false, true] {
            let end = cue.pose(at: cue.duration - 0.0005, reducedMotion: reduced)
            #expect(end.lid > 0.99, "\(cue) lid")
            #expect(abs(end.lean) < 0.01, "\(cue) lean")
            #expect(abs(end.toward) < 0.01, "\(cue) toward")
            #expect(abs(end.sag) < 0.01, "\(cue) sag")
            #expect(abs(end.swell) < 0.01, "\(cue) swell")
            #expect(abs(end.stretch - 1) < 0.01, "\(cue) stretch")
            #expect(abs(end.openMultiplier - 1) < 0.01, "\(cue) openMultiplier")
        }
    }

    @Test func boopSqueezesIntoWideSlits() {
        var face = Self.headFace
        face.cue = .boop
        face.cueStart = 20
        let rest = Self.headFace.sample(at: 20.3)
        let squeezed = face.sample(at: 20.3)
        #expect(squeezed.left.size.height < PeekMetrics.head.eyeSize.height * 0.3)
        #expect(squeezed.left.size.width > rest.left.size.width * 1.25)
        #expect(squeezed.swell > 1)
        var quiet = face
        quiet.reducedMotion = true
        #expect(quiet.sample(at: 20.3).swell == 0)
        #expect(quiet.sample(at: 20.3).left.size.height < PeekMetrics.head.eyeSize.height * 0.3)
    }

    @Test func heyLooksIntoTheScreenAndNudgesTwice() {
        var face = Self.headFace
        face.mood = .waiting
        face.cue = .hey
        face.cueStart = 30
        // inward is -x for the head on the right edge.
        #expect(face.sample(at: 30.11).left.center.x < face.sample(at: 30).left.center.x - 0.4)
        var peaks = 0
        var above = false
        for step in 0...Int(PeekCue.hey.duration * 120) {
            let swollen = face.sample(at: 30 + Double(step) / 120).swell > 2
            if swollen, !above { peaks += 1 }
            above = swollen
        }
        #expect(peaks == 2)
    }

    @Test(arguments: PeekCue.allCases)
    func cueEyesStayInsideThePill(cue: PeekCue) {
        let halfLength = NotchMetrics.pillLength / 2
        let halfThickness = NotchMetrics.pillThickness / 2
        for mood in PeekMood.allCases {
            var face = Self.pillFace
            face.mood = mood
            face.cue = cue
            face.cueStart = 0
            for step in 0...Int(cue.duration * 60) {
                let frame = face.sample(at: Double(step) / 60)
                for eye in [frame.left, frame.right] {
                    for corner in Self.corners(eye) {
                        #expect(abs(corner.x) <= halfLength + 0.01, "\(cue) \(mood)")
                        #expect(abs(corner.y) <= halfThickness + 0.01, "\(cue) \(mood) t=\(Double(step) / 60)")
                    }
                }
            }
        }
    }
}
