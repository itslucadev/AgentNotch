import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentNotch

/// Renders the real `NotchRootView` off screen and reads pixels back: the eyes must show up in
/// the composed notch, where clipping, placement and opacity all have to line up for them to.
@MainActor
struct PeekRenderTests {
    private struct StubProvider: UsageProvider {
        let id: ProviderID
        let outcome: Result<ProviderSnapshot, UsageProviderError>
        func fetch() async throws -> ProviderSnapshot { try outcome.get() }
    }

    private func makeModel(visibility: NotchVisibility, provider: StubProvider) async -> NotchViewModel {
        let defaults = UserDefaults(suiteName: "PeekRenderTests.\(UUID().uuidString)")!
        defaults.set(NotchEdge.right.rawValue, forKey: "notchEdge")
        defaults.set(visibility.rawValue, forKey: "notchVisibility")
        defaults.set(
            ProviderID.allCases.filter { $0 != provider.id }.map(\.rawValue), forKey: "hiddenProviders")
        let store = UsageStore(providers: [provider], defaults: defaults)
        store.refresh(provider.id)
        while store.isRefreshing { await Task.yield() }
        return NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
    }

    private func render(_ model: NotchViewModel, named name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: NotchRootView(model: model))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(name).png")
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        return image
    }

    /// Pixels brighter than mid grey inside `rect` (points), which on a black disc can only be eyes.
    private func brightPixels(in image: CGImage, rect: CGRect, scale: CGFloat = 2) throws -> Int {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        let x0 = Int(rect.minX * scale)
        let x1 = min(Int(rect.maxX * scale), width)
        let y0 = Int(rect.minY * scale)
        let y1 = min(Int(rect.maxY * scale), height)
        for y in y0..<y1 {
            for x in x0..<x1 {
                // Bitmap context memory is stored top-down, matching SwiftUI's rect.
                let offset = (y * width + x) * 4
                if bytes[offset] > 128, bytes[offset + 1] > 128, bytes[offset + 2] > 128, bytes[offset + 3] > 128 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test func expandedNotchShowsTheHeadWithEyes() async throws {
        // `failed` never blinks, so the render is the same whichever instant the timeline picks.
        let model = await makeModel(
            visibility: .alwaysShow, provider: StubProvider(id: .claude, outcome: .failure(.unavailable("x"))))
        #expect(model.isExpanded)
        #expect(model.mood == .failed)
        let image = try render(model, named: "expanded-failed")
        let layout = model.layout
        let eyes = try brightPixels(in: image, rect: layout.headRect)
        // Two squinted eyes at 2x: 7 × 3.6 pt each, ~200 px in all; a full blink would leave under 40.
        #expect(eyes > 120, "eyes in the head: \(eyes) bright pixels")
        #expect(try brightPixels(in: image, rect: layout.pillRect) == 0, "the pill's eyes are hidden while expanded")
    }

    @Test func aPlayingClipReplacesTheHead() async throws {
        let model = await makeModel(
            visibility: .alwaysShow, provider: StubProvider(id: .claude, outcome: .failure(.unavailable("x"))))
        model.previewClip(.notification)
        #expect(model.peekClip == .notification)
        let image = try render(model, named: "expanded-clip")
        let layout = model.layout
        let eyes = try brightPixels(in: image, rect: layout.headRect)
        // The clip's first frame has the bot's full open eyes: about 3 400 px at 320, so around
        // 750 px once the 203 px body sits on the 48 pt disc at 2x. The squinted `failed` face
        // the clip covers would leave ~200.
        #expect(eyes > 450, "clip eyes in the head: \(eyes) bright pixels")
    }

    @Test func collapsedNotchShowsEyesInThePill() async throws {
        let model = await makeModel(
            visibility: .onHover, provider: StubProvider(id: .claude, outcome: .failure(.unavailable("x"))))
        #expect(!model.isExpanded)
        let image = try render(model, named: "collapsed-failed")
        let layout = model.layout
        let eyes = try brightPixels(in: image, rect: layout.pillRect)
        // Two squinted 11 × 5.3 pt eyes at 2x.
        #expect(eyes > 40, "eyes in the pill: \(eyes) bright pixels")
        #expect(try brightPixels(in: image, rect: layout.headRect) == 0, "the head is hidden while collapsed")
    }

    @Test func collapsedIdleRendersEyesThatRead() async throws {
        let now = Date()
        let snapshot = ProviderSnapshot(
            id: .claude, account: nil, plan: nil,
            windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.31, resetsAt: nil)],
            sessions: [AgentSession(id: "s", name: "bloub", detail: "", activity: .idle, startedAt: now)],
            fetchedAt: now)
        let model = await makeModel(
            visibility: .onHover, provider: StubProvider(id: .claude, outcome: .success(snapshot)))
        #expect(!model.isExpanded)
        #expect(model.mood == .idle)
        let image = try render(model, named: "collapsed-idle")
        let eyes = try brightPixels(in: image, rect: model.layout.pillRect)
        // Two 11 × 14 pt idle eyes at 2x, clipped to the 25 pt pill.
        #expect(eyes > 120, "idle eyes in the pill: \(eyes) bright pixels")
    }

    @Test func idleHeadRendersForInspection() async throws {
        let now = Date()
        let snapshot = ProviderSnapshot(
            id: .claude, account: nil, plan: nil,
            windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.31, resetsAt: nil)],
            sessions: [AgentSession(id: "s", name: "bloub", detail: "", activity: .idle, startedAt: now)],
            fetchedAt: now)
        let model = await makeModel(
            visibility: .alwaysShow, provider: StubProvider(id: .claude, outcome: .success(snapshot)))
        #expect(model.mood == .idle)
        _ = try render(model, named: "expanded-idle")
    }

}
