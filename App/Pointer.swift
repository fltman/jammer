import AppKit

/// The pointer never stays as a shape that means nothing where it is (COMFORT 45). A view sets its pointer as the mouse
/// moves over it (its tracking area); this sets it again when something else changes what a press would do there — a
/// drag that ended, a tool or ⌥ changed with the mouse still — and gives the arrow back when the pointer this view set
/// is left behind: a drag that ended outside it, the mouse gone out to a view with no pointer of its own, the view
/// hidden or taken away under it. Another view's pointer is never touched: the arrow is set only on what was ours.
@MainActor
enum Pointer {
    /// The pointer `shape` gives at the mouse, when the mouse is over `view` in the key window. `ours`: the pointer
    /// was this view's (a drag of its own just ended), so when the mouse is elsewhere it is the arrow again.
    static func refresh(_ view: NSView, ours: Bool = false, _ shape: (NSPoint) -> NSCursor) {
        guard let window = view.window, window.isKeyWindow else { return }
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !view.isHiddenOrHasHiddenAncestor, view.visibleRect.contains(p) { shape(p).set() } else if ours { NSCursor.arrow.set() }
    }

    /// The mouse went out of `view` with no button down: the arrow, unless the view it went to sets its own (that
    /// one's tracking area sets it after this).
    static func left(_ view: NSView) {
        if NSEvent.pressedMouseButtons == 0 { NSCursor.arrow.set() }
    }

    /// `view` is hidden or leaves its window: if the mouse is over it, its pointer goes with it.
    static func gone(_ view: NSView) {
        guard let window = view.window else { return }
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if view.bounds.contains(p) { NSCursor.arrow.set() }
    }
}
