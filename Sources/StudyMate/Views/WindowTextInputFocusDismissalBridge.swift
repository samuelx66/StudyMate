import AppKit
import SwiftUI

/// macOS does not automatically resign an NSTextField when the user clicks a
/// non-focusable SwiftUI control or an empty Canvas area. Install one local
/// mouse monitor for the main window so subtitle edits consistently commit and
/// both text fields lose focus whenever the click is outside another text input.
struct WindowTextInputFocusDismissalBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusDismissalNSView {
        FocusDismissalNSView(frame: .zero)
    }

    func updateNSView(_ nsView: FocusDismissalNSView, context: Context) {}
}

final class FocusDismissalNSView: NSView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.dismissTextFocusIfNeeded(for: event)
            return event
        }
    }

    deinit {
        removeMonitor()
    }

    private func dismissTextFocusIfNeeded(for event: NSEvent) {
        guard let window, event.window === window else { return }
        guard let textView = window.firstResponder as? NSTextView, textView.isEditable else { return }
        let hitView = window.contentView?.hitTest(event.locationInWindow)
        guard !isInsideTextInput(hitView) else { return }
        window.makeFirstResponder(nil)
    }

    private func isInsideTextInput(_ view: NSView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is NSTextField || current is NSTextView { return true }
            candidate = current.superview
        }
        return false
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
