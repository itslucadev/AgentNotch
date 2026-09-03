import CoreGraphics
import Foundation
import ImageIO

/// A hand-made beat exported from bloub and played over Peek's head for one event: the bot
/// itself, at 20 fps with a transparent background. Where `PeekCue` is computed, a clip is
/// authored; both are one-shots on top of the mood, and the mood resumes after.
nonisolated enum PeekClip: String, CaseIterable, Sendable {
    /// A limit window came back.
    case reset = "peek-reset"
    /// A general notification. Nothing triggers it yet; it ships ready beside the other two.
    case notification = "peek-notification"
    /// The headline window entered the critical band.
    case creditsLow = "peek-credits-low"

    /// Side of the square the clip is drawn in, centred on the head. bloub exports the bot in a
    /// 320 px frame with a 203 px body (measured off the frames), so this puts the body exactly
    /// on the 48 pt disc; the rings of the reset clip reach 33 pt out and fit the 12 pt gap.
    static let side: CGFloat = NotchMetrics.orbDiameter * 320 / 203

    /// The clip a mood change deserves, if any. Where one exists it replaces the computed cue
    /// of `PeekCue.onMoodChange`, which stays as the fallback when the clip cannot be loaded.
    static func onMoodChange(from previous: PeekMood, to mood: PeekMood) -> PeekClip? {
        guard previous != mood, previous != .exhausted, mood == .critical else { return nil }
        return .creditsLow
    }
}

/// The decoded frames of one clip and when each starts. `CGImage` is immutable, so sharing the
/// array across actors is safe.
nonisolated struct PeekClipFrames: @unchecked Sendable {
    let images: [CGImage]
    /// Start of each frame from the clip's beginning; the last entry is the total duration.
    let starts: [TimeInterval]

    var duration: TimeInterval { starts.last ?? 0 }

    /// The frame showing at `u` seconds in, nil once the clip is over.
    func image(at u: TimeInterval) -> CGImage? {
        guard u >= 0, u < duration else { return nil }
        var low = 0
        var high = images.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= u { low = mid } else { high = mid - 1 }
        }
        return images[low]
    }

    /// Reads an APNG from the bundle. Delays come from the file; a frame without one gets 50 ms,
    /// bloub's export rate.
    static func load(_ clip: PeekClip, bundle: Bundle = .main) -> PeekClipFrames? {
        guard let url = bundle.url(forResource: clip.rawValue, withExtension: "apng"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var images: [CGImage] = []
        var starts: [TimeInterval] = []
        images.reserveCapacity(count)
        starts.reserveCapacity(count + 1)
        var t: TimeInterval = 0
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            images.append(image)
            starts.append(t)
            t += delay(source, index)
        }
        starts.append(t)
        return PeekClipFrames(images: images, starts: starts)
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        else { return 0.05 }
        let unclamped = png[kCGImagePropertyAPNGUnclampedDelayTime] as? TimeInterval
        let clamped = png[kCGImagePropertyAPNGDelayTime] as? TimeInterval
        let value = unclamped ?? clamped ?? 0.05
        return value > 0 ? value : 0.05
    }
}

/// One decode per clip per process. Main-actor because the view is the only reader and the
/// first play of each clip is the only time it costs anything.
@MainActor
enum PeekClipLibrary {
    private static var cache: [PeekClip: PeekClipFrames] = [:]

    static func frames(for clip: PeekClip) -> PeekClipFrames? {
        if let cached = cache[clip] { return cached }
        guard let loaded = PeekClipFrames.load(clip) else { return nil }
        cache[clip] = loaded
        return loaded
    }
}
