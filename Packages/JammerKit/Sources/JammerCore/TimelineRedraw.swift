/// What the timeline draws again when the session changes (the performance pass, 2026-11-26). Playing set the playhead
/// 60 times a second, and every move drew the whole timeline again on the CPU (the ruler, every clip with its name and
/// fades, every marker, both kinds of automation lane) for a line 1.5 points wide: about one core while playing. The
/// playhead is a layer of its own now, moved without drawing anything; the timeline is drawn again only when the
/// project, the selection or playing changes, or when following turns a page (at most twice a second, FollowPolicy),
/// and then once, never once for the page and once more for the change that brought it.
public enum TimelineRedraw {
    public enum Change: Sendable, Equatable {
        /// Only the playhead moved.
        case playhead
        /// The project, the selection or whether it plays.
        case content
    }

    public struct Plan: Sendable, Equatable {
        /// The playhead's layer is put where the playhead is (always: a change of content can move it too).
        public var movePlayhead: Bool
        /// How many times the timeline is drawn again: 0 or 1.
        public var refreshes: Int
        public init(movePlayhead: Bool, refreshes: Int) { self.movePlayhead = movePlayhead; self.refreshes = refreshes }
    }

    public static func plan(_ change: Change, follow: FollowPolicy.Decision) -> Plan {
        switch (change, follow) {
        case (.content, _), (.playhead, .page): Plan(movePlayhead: true, refreshes: 1)
        case (.playhead, .stay), (.playhead, .paused): Plan(movePlayhead: true, refreshes: 0)
        }
    }
}
