import AppKit
import SwiftUI

/// Two-finger trackpad scrolls and mouse wheels pan the canvas; with ⌘ held they zoom. SwiftUI has
/// no scroll-wheel gesture on macOS, so a local event monitor catches scrolls over this view's
/// bounds. Clicks pass straight through.
struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (_ delta: CGSize, _ location: CGPoint, _ zoom: Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize, CGPoint, Bool) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return event }
            // Mouse wheels report lines; trackpads report points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            onScroll?(
                CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale),
                location, event.modifierFlags.contains(.command)
            )
            return nil
        }
    }
}
