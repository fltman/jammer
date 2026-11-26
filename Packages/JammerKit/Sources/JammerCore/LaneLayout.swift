/// Where the tracks' lanes lie on the timeline (Anders, 2026-11-26: "saknar du en scroll på höjden när du har många
/// spår?"). Until now each lane got the timeline's height divided by the number of tracks, so 24 tracks left lanes under
/// 30 points. A lane is now at least `minimum` × the track zoom high; when the tracks don't fit, they scroll, and a thin
/// row at the top and the bottom of the tracks' area says how many tracks out of view the selection reaches into.
///
/// One layout for everything that draws or hits a lane (the waveform, the overlay, the handles, the automation lanes,
/// the track headers), so none of them can disagree. Positions are in points from the top of the timeline (the ruler
/// above, the lanes under it); the strips' rows below are not in it.
public struct LaneLayout: Sendable, Equatable {
    /// A lane's least height at track zoom 1.
    public static let minimum = 48.0
    public static let zoomRange = 0.5...4.0
    /// The row at the top and at the bottom of the tracks' area while they scroll (the hidden tracks' mark lives there,
    /// over no lane, so it never covers a handle or a point).
    public static let edgeRow = 14.0

    public let tracks: Int
    /// The ruler's height, above the tracks' area.
    public let rulerHeight: Double
    /// The tracks' area: from under the ruler to the bottom of the timeline (strips' rows excluded).
    public let areaHeight: Double
    public let zoom: Double
    /// How far the lanes are scrolled, in points: always within 0…maxScroll.
    public let scrollY: Double

    public init(tracks: Int, rulerHeight: Double, areaHeight: Double, zoom: Double = 1, scrollY: Double = 0) {
        self.tracks = max(0, tracks)
        self.rulerHeight = rulerHeight
        self.areaHeight = max(0, areaHeight)
        self.zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        let n = Double(max(1, tracks))
        let wanted = Self.minimum * self.zoom
        let fits = wanted * n <= self.areaHeight
        let edge = fits ? 0 : Self.edgeRow
        let visible = max(0, self.areaHeight - 2 * edge)
        let lane = fits ? max(wanted, self.areaHeight / n) : wanted
        self.edge = edge
        self.visibleHeight = visible
        self.laneHeight = lane
        let maxScroll = max(0, lane * Double(self.tracks) - visible)
        self.maxScroll = maxScroll
        self.scrollY = min(maxScroll, max(0, scrollY))
    }

    /// The height of the edge rows (0 while everything fits).
    public let edge: Double
    /// The height the lanes are seen in.
    public let visibleHeight: Double
    public let laneHeight: Double
    public let maxScroll: Double
    public var overflows: Bool { maxScroll > 0 }

    /// Where the lanes are seen: from `lanesTop` to `lanesBottom`.
    public var lanesTop: Double { rulerHeight + edge }
    public var lanesBottom: Double { lanesTop + visibleHeight }
    public var contentHeight: Double { laneHeight * Double(tracks) }

    /// The top of lane `i`, scrolled (it may lie outside what is seen).
    public func laneTop(_ i: Int) -> Double { lanesTop + Double(i) * laneHeight - scrollY }

    /// The lane under `y`, if a lane is seen there.
    public func lane(atY y: Double) -> Int? {
        guard y >= lanesTop, y < lanesBottom, laneHeight > 0 else { return nil }
        let i = Int((y - lanesTop + scrollY) / laneHeight)
        return i >= 0 && i < tracks ? i : nil
    }

    /// The lanes at least partly seen.
    public var visibleLanes: Range<Int> {
        guard tracks > 0, laneHeight > 0 else { return 0..<0 }
        let first = Int(scrollY / laneHeight)
        let last = Int(((scrollY + visibleHeight) / laneHeight).rounded(.up))
        return min(tracks, first)..<min(tracks, max(first, last))
    }

    /// Whether all of lane `i` is seen.
    public func isWhollyVisible(_ i: Int) -> Bool {
        laneTop(i) >= lanesTop - 0.5 && laneTop(i) + laneHeight <= lanesBottom + 0.5
    }

    // MARK: Moving

    public func scrolled(to y: Double) -> LaneLayout {
        LaneLayout(tracks: tracks, rulerHeight: rulerHeight, areaHeight: areaHeight, zoom: zoom, scrollY: y)
    }

    public func scrolled(by dy: Double) -> LaneLayout { scrolled(to: scrollY + dy) }

    /// Lane `i` brought into view with as little scrolling as can be (nothing moves if it is seen already): for the
    /// focus, the selected track, a track the agent selects, a new track at the bottom.
    public func revealing(_ i: Int) -> LaneLayout {
        guard i >= 0, i < tracks, !isWhollyVisible(i) else { return self }
        let top = Double(i) * laneHeight
        if top < scrollY { return scrolled(to: top) }
        return scrolled(to: top + laneHeight - visibleHeight)
    }

    /// The track zoom changed by `factor`, the point at `anchorY` (in the lanes) staying over the same place in its lane.
    public func zoomed(by factor: Double, anchorY: Double? = nil) -> LaneLayout {
        let newZoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        let wider = LaneLayout(tracks: tracks, rulerHeight: rulerHeight, areaHeight: areaHeight, zoom: newZoom, scrollY: 0)
        let y = min(lanesBottom, max(lanesTop, anchorY ?? (lanesTop + visibleHeight / 2)))
        // The content position under the anchor, as a share of the content, kept under the anchor.
        let share = contentHeight > 0 ? (y - lanesTop + scrollY) / contentHeight : 0
        return wider.scrolled(to: share * wider.contentHeight - (y - wider.lanesTop))
    }

    /// The zoom that shows every track, when it can (never below the zoom range).
    public func fitted() -> LaneLayout {
        let n = Double(max(1, tracks))
        let zoom = min(1, max(Self.zoomRange.lowerBound, areaHeight / n / Self.minimum))
        return LaneLayout(tracks: tracks, rulerHeight: rulerHeight, areaHeight: areaHeight, zoom: zoom, scrollY: 0)
    }

    // MARK: The hidden tracks' mark

    /// Of `tracks` (those with something in the selection), the ones above and below what is seen. A lane partly seen
    /// counts as seen.
    public func hidden(_ reached: [Int]) -> (above: [Int], below: [Int]) {
        let seen = visibleLanes
        let above = reached.filter { $0 < seen.lowerBound }.sorted()
        let below = reached.filter { $0 >= seen.upperBound }.sorted()
        return (above, below)
    }
}
