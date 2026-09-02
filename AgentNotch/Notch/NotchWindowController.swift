import AppKit
import Observation
import SwiftUI

/// Transparent, non-activating panel that floats above everything and never takes focus.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Places the notch on the screen edge and feeds pointer movement into the view model.
final class NotchWindowController {
    let model: NotchViewModel
    private let panel: NotchPanel
    private let hostingView: NSHostingView<NotchRootView>
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    init(model: NotchViewModel) {
        self.model = model
        let size = model.panelSize
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        hostingView = NSHostingView(rootView: NotchRootView(model: model))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.layout() }
        }
        observeLayout()
        installMouseMonitors()
        layout()
    }

    /// Re-runs whenever anything that affects the panel frame changes.
    private func observeLayout() {
        withObservationTracking {
            _ = model.panelSize
            _ = model.edge
            _ = model.preferences.notchVisibility
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.visibilityChanged()
                self.layout()
                self.observeLayout()
            }
        }
    }

    /// The display the notch lives on: the one carrying the menu bar.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first
    }

    func layout() {
        guard model.preferences.notchVisibility != .hidden, let screen = targetScreen else {
            panel.orderOut(nil)
            return
        }
        let size = model.panelSize
        let visible = screen.visibleFrame
        let origin: NSPoint
        switch model.edge {
        case .right: origin = NSPoint(x: visible.maxX - size.width, y: (visible.midY - size.height / 2).rounded())
        case .left: origin = NSPoint(x: visible.minX, y: (visible.midY - size.height / 2).rounded())
        case .top: origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.maxY - size.height)
        case .bottom: origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY)
        }
        let frame = NSRect(origin: origin, size: size)
        panel.setFrame(frame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] _ in
                self?.pointerMoved()
            })
        {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                self?.pointerMoved()
                return event
            })
        {
            monitors.append(local)
        }
    }

    private func pointerMoved() {
        guard panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(location) else {
            model.pointerMoved(to: nil)
            return
        }
        // Flip into the SwiftUI coordinate space used by the view model.
        let local = CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y)
        model.pointerMoved(to: local)
    }
}
