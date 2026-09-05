import AppKit
import SwiftUI

/// Renders the live notch view to numbered PNGs at 20 fps while a scenario plays out on the
/// real view model, for the clips in `Design/`. The shell that builds them cannot capture the
/// screen, and a screen recording would not be more faithful anyway: this is the same
/// `NotchRootView` the window shows, sampled at the same dates, with its timers running.
///
/// Post `app.lucabecker.AgentNotch.recordScenario` with the scenario as the object and the
/// output folder under `userInfo["directory"]`. The folder ends up with `frame-NNNN.png` and
/// `frames.txt`, an ffmpeg concat list carrying each frame's real duration. The frames are
/// transparent; `Design/peek-*.mp4` were laid over a flat colour like so:
///
///     ffmpeg -f concat -safe 0 -i frames.txt -f lavfi -i color=c=0x6B7A94:s=694x1207:r=20 \
///       -filter_complex "[1][0]overlay=shortest=1:format=auto,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" \
///       -c:v libx264 -crf 18 -r 20 -movflags +faststart peek-reset.mp4
@MainActor
final class NotchRecorder {
    enum Scenario: String, CaseIterable {
        case reset
        case exhausted
        case creditsLow = "credits-low"
        case notification
    }

    private let model: NotchViewModel
    private var timer: Timer?
    private var directory: URL?
    private var stamps: [TimeInterval] = []
    private var isDone: () -> Bool = { true }
    private var doneAt: TimeInterval?

    /// Kept after the scenario ends so the settle back to rest is on film too.
    private let tail: TimeInterval = 1.2
    private let interval: TimeInterval = 1 / 20

    init(model: NotchViewModel) {
        self.model = model
    }

    func record(_ scenario: Scenario, into directory: URL) {
        stop()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        stamps.removeAll()
        doneAt = nil

        switch scenario {
        case .reset:
            model.previewLimitNotification(.reset)
            isDone = { [model] in !model.isNotifying }
        case .exhausted:
            model.previewLimitNotification(.exhausted)
            isDone = { [model] in !model.isNotifying }
        case .creditsLow:
            model.previewClip(.creditsLow)
            isDone = { [model] in model.peekClip == nil }
        case .notification:
            model.previewClip(.notification)
            isDone = { [model] in model.peekClip == nil }
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let directory else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let renderer = ImageRenderer(content: NotchRootView(model: model))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let index = stamps.count
        stamps.append(now)
        let url = directory.appendingPathComponent(String(format: "frame-%04d.png", index))
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)

        if doneAt == nil, isDone() {
            doneAt = now
        }
        if let doneAt, now - doneAt >= tail {
            finish()
        }
    }

    private func finish() {
        guard let directory else { return }
        var list = ""
        for (index, stamp) in stamps.enumerated() {
            let next = index + 1 < stamps.count ? stamps[index + 1] : stamp + interval
            list += String(format: "file 'frame-%04d.png'\nduration %.4f\n", index, next - stamp)
        }
        try? list.write(to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        directory = nil
    }
}
