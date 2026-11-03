import AppKit
import SwiftUI
import WardenBarDesktop

/// MenuBarExtra can retain its native panel size when SwiftUI's fixed frame changes.
/// Bridge the requested width to that panel instead of letting the hosting view clip it.
@MainActor
struct PopoverWindowWidth: NSViewRepresentable {
    let width: Double

    func makeNSView(context: Context) -> WindowWidthView { WindowWidthView() }

    func updateNSView(_ view: WindowWidthView, context: Context) {
        view.request(width: width)
    }
}

@MainActor
final class WindowWidthView: NSView {
    private var requestedWidth = PopoverWidth.defaultValue
    private var pending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleResize()
    }

    func request(width: Double) {
        requestedWidth = PopoverWidth.clamp(width)
        scheduleResize()
    }

    private func scheduleResize() {
        guard !pending else { return }
        pending = true
        // Apply after SwiftUI's layout update; coalesce events and use the latest requested size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.resizeWindow()
        }
    }

    private func resizeWindow() {
        guard let window else { return }
        let oldFrame = window.frame
        let content = window.contentRect(forFrameRect: oldFrame)
        guard abs(content.width - CGFloat(requestedWidth)) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: CGFloat(requestedWidth), height: content.height))
        frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        }
        window.setFrame(frame, display: true, animate: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
