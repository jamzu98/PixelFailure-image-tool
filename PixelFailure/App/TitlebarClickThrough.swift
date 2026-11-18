import AppKit

/// Keeps the empty title bar draggable while the native document title is
/// shown. AppKit stretches the title's container across all free toolbar
/// space and that container eats mouse-downs, so drags and double-click zoom
/// only work in thin strips at the bar's edges. Clicks that land on the bare
/// container (not on the title text itself) go to the enclosing title view,
/// which runs the system's own drag and double-click handling.
enum TitlebarClickThrough {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { redirect(event) }
            return handled ? nil : event
        }
    }

    private static func redirect(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow),
              className(of: hit) == "NSToolbarPrimaryTitleContainerView",
              let titleView = ancestors(of: hit).first(where: {
                  className(of: $0) == "NSToolbarTitleView"
              })
        else { return false }
        titleView.mouseDown(with: event)
        return true
    }

    private static func ancestors(of view: NSView) -> some Sequence<NSView> {
        sequence(first: view.superview, next: { $0?.superview }).lazy.compactMap { $0 }
    }

    private static func className(of view: NSView) -> String {
        String(describing: type(of: view))
    }
}
