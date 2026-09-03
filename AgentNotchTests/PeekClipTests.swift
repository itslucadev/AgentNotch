import CoreGraphics
import Foundation
import Testing

@testable import AgentNotch

/// The three bloub exports are in the bundle, decode with their timing, and were keyed: the
/// margin is clear, the body opaque and the eyes still white.
struct PeekClipTests {
    private static let expectedFrames: [PeekClip: Int] = [
        .reset: 130, .notification: 102, .creditsLow: 110,
    ]

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var buffer = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    @Test(arguments: PeekClip.allCases)
    func clipDecodesAtTwentyFramesPerSecond(_ clip: PeekClip) {
        let frames = PeekClipFrames.load(clip)
        guard let frames else {
            Issue.record("\(clip.rawValue).apng missing from the app bundle")
            return
        }
        let count = Self.expectedFrames[clip]!
        #expect(frames.images.count == count)
        #expect(frames.starts.count == count + 1)
        #expect(abs(frames.duration - Double(count) * 0.05) < 0.001)
        #expect(frames.images.allSatisfy { $0.width == 320 && $0.height == 320 })
    }

    @Test(arguments: PeekClip.allCases)
    func frameLookupFollowsTheTimeline(_ clip: PeekClip) throws {
        let frames = try #require(PeekClipFrames.load(clip))
        #expect(frames.image(at: -0.01) == nil)
        #expect(frames.image(at: 0) === frames.images[0])
        // ImageIO hands the delay back as a Float, so the boundary sits a hair past 0.05.
        #expect(frames.image(at: 0.049) === frames.images[0])
        #expect(frames.image(at: 0.051) === frames.images[1])
        #expect(frames.image(at: frames.duration - 0.001) === frames.images.last!)
        #expect(frames.image(at: frames.duration) == nil)
    }

    @Test(arguments: PeekClip.allCases)
    func firstFrameIsKeyedWithWhiteEyesKept(_ clip: PeekClip) throws {
        let frames = try #require(PeekClipFrames.load(clip))
        let first = frames.images[0]
        #expect(first.alphaInfo != .none && first.alphaInfo != .noneSkipLast && first.alphaInfo != .noneSkipFirst)
        #expect(pixel(first, x: 2, y: 2).a == 0, "the margin around the bot is transparent")
        let centre = pixel(first, x: 160, y: 160)
        #expect(centre.a == 255 && centre.r < 30, "the body is the bot's black")
        // The eyes sit above the centre, white and opaque, somewhere in the upper half of the body.
        var whiteInside = 0
        for y in stride(from: 90, to: 160, by: 2) {
            for x in stride(from: 90, to: 230, by: 2) {
                let p = pixel(first, x: x, y: y)
                if p.a == 255 && p.r > 240 && p.g > 240 && p.b > 240 { whiteInside += 1 }
            }
        }
        #expect(whiteInside > 20, "the white eyes survived the keying")
    }
}
