import Foundation

/// What a press on the timeline grabs, and the pointer that says so, from one source (the comfort list: "the
/// pointer shows what a press does, from the same zones as the press"; Glimmer's HandleZones). The window lays out
/// the clips, the selection and the markers in points; this decides, with no AppKit, so it can be tested.
public enum HandleZones {
    /// The pointer a zone shows (the window maps it to an NSCursor).
    public enum Pointer: String, Sendable, Equatable { case arrow, iBeam, resizeLeftRight, openHand, crosshair, pointingHand }

    public enum Zone: Sendable, Equatable {
        /// The ruler: a click moves the playhead.
        case ruler
        /// A marker's flag: drag to move it, double-click to rename.
        case marker(UUID)
        case selectionStart, selectionEnd
        case fadeIn(clip: UUID), fadeOut(clip: UUID)
        case trimStart(clip: UUID), trimEnd(clip: UUID)
        /// Where a plain drag selects a range.
        case lane(Int)
        /// Below the last lane, or outside everything.
        case none

        public var pointer: Pointer {
            switch self {
            case .ruler, .none: .arrow
            case .marker: .openHand
            case .selectionStart, .selectionEnd, .fadeIn, .fadeOut, .trimStart, .trimEnd: .resizeLeftRight
            case .lane: .iBeam
            }
        }
    }

    /// One clip as drawn: its edges and the ends of its fades, in points.
    public struct ClipBox: Sendable {
        public var id: UUID
        public var start: Double, end: Double
        public var fadeInEnd: Double, fadeOutStart: Double
        public init(id: UUID, start: Double, end: Double, fadeInEnd: Double, fadeOutStart: Double) {
            self.id = id; self.start = start; self.end = end; self.fadeInEnd = fadeInEnd; self.fadeOutStart = fadeOutStart
        }
        /// Where the fade handles stand: at the end of each fade, but never closer to the clip's edge than a
        /// handle's width (a clip at 0 s would otherwise put its handle on the window's edge, where macOS takes the
        /// press for resizing the window; found trying it, 2026-11-25).
        public var fadeInHandle: Double { max(fadeInEnd, start + HandleZones.fadeHandle / 2 + 2) }
        public var fadeOutHandle: Double { min(fadeOutStart, end - HandleZones.fadeHandle / 2 - 2) }
    }

    public struct MarkerFlag: Sendable {
        public var id: UUID
        public var x: Double, width: Double
        public init(id: UUID, x: Double, width: Double) { self.id = id; self.x = x; self.width = width }
    }

    public struct Layout: Sendable {
        public var rulerHeight: Double
        public var laneHeight: Double
        public var lanes: [[ClipBox]]
        /// The selection's edges in points, when there is one.
        public var selection: (start: Double, end: Double)?
        public var markers: [MarkerFlag]
        /// A flag's height, under the ruler.
        public var flagHeight: Double = 14
        /// The Trim tool: a clip's edges are grabbed over the whole height of the lane.
        public var trimAnywhere = false
        public init(rulerHeight: Double, laneHeight: Double, lanes: [[ClipBox]], selection: (start: Double, end: Double)?, markers: [MarkerFlag]) {
            self.rulerHeight = rulerHeight; self.laneHeight = laneHeight; self.lanes = lanes; self.selection = selection; self.markers = markers
        }
    }

    /// Half the width of a grip: the hit area is at least 8 pt wide whatever is drawn (the comfort list).
    public static let grip = 4.0
    /// The fade handle's square, at the top of the lane.
    public static let fadeHandle = 8.0

    /// What is under a point. The order is the priority: a fade handle over a selection edge over a clip edge.
    public static func zone(at x: Double, _ y: Double, in l: Layout) -> Zone {
        if y < l.rulerHeight { return .ruler }
        let lane = Int((y - l.rulerHeight) / max(1, l.laneHeight))
        guard lane >= 0, lane < l.lanes.count else { return .none }
        let top = l.rulerHeight + Double(lane) * l.laneHeight
        // Marker flags hang under the ruler in the first lane's top row.
        if lane == 0, y < l.rulerHeight + 2 + l.flagHeight, let m = l.markers.first(where: { x >= $0.x - grip && x <= $0.x + $0.width }) {
            return .marker(m.id)
        }
        let clips = l.lanes[lane]
        // Fade handles: a square at the top of the lane where each fade ends (or at the clip's corner when it has none).
        if y < top + fadeHandle + 4 {
            for c in clips where c.end - c.start > 3 * fadeHandle {
                if abs(x - c.fadeInHandle) <= fadeHandle / 2 + 1 { return .fadeIn(clip: c.id) }
                if abs(x - c.fadeOutHandle) <= fadeHandle / 2 + 1 { return .fadeOut(clip: c.id) }
            }
        }
        if let s = l.selection {
            if abs(x - s.start) <= grip { return .selectionStart }
            if abs(x - s.end) <= grip { return .selectionEnd }
        }
        // Clip edges, in the lower half of the lane (the upper half keeps its plain selection drag).
        if l.trimAnywhere || y > top + l.laneHeight / 2 {
            for c in clips {
                if abs(x - c.start) <= grip { return .trimStart(clip: c.id) }
                if abs(x - c.end) <= grip { return .trimEnd(clip: c.id) }
            }
        }
        return .lane(lane)
    }

    /// The nearest snap target within `distance` points, or nil (clip edges, markers, the playhead, the selection).
    public static func snap(_ x: Double, to targets: [Double], within distance: Double = 6) -> Double? {
        targets.filter { abs($0 - x) <= distance }.min { abs($0 - x) < abs($1 - x) }
    }
}
