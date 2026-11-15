import Foundation

extension UndoManager {
    /// Registers `body` as its own top-level undo step, also outside the event loop
    /// (agent requests, finished jobs). With groupsByEvent on, AppKit opens an automatic
    /// group around a registration and closes it only after a user event, so steps that
    /// arrive without events pile into one group; closing that group by hand can later
    /// throw "endUndoGrouping called with no matching begin". So groupsByEvent is off
    /// while the step is grouped explicitly, and no automatic group is ever opened.
    /// Inside undo or redo, or inside an open group (a user event), it registers as is.
    public func separateStep(_ body: () -> Void) {
        guard !isUndoing, !isRedoing, groupingLevel == 0 else { body(); return }
        let byEvent = groupsByEvent
        groupsByEvent = false
        beginUndoGrouping()
        body()
        endUndoGrouping()
        groupsByEvent = byEvent
    }
}
