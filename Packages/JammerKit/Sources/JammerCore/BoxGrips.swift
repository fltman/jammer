/// The grips of a drawn box (the spectral area's box): a corner or an edge resizes it, the inside moves it (the
/// comfort sweep of 2026-11-25, [2]: a box a little wrong had to be drawn again). In the view's points with y going
/// down; pure, so the zone the pointer shows is the zone a press takes.
public enum BoxGrips {
    public struct Rect: Equatable, Sendable {
        public var minX: Double, minY: Double, maxX: Double, maxY: Double
        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = min(minX, maxX); self.maxX = max(minX, maxX)
            self.minY = min(minY, maxY); self.maxY = max(minY, maxY)
        }
        public var width: Double { maxX - minX }
        public var height: Double { maxY - minY }
    }
    public enum Edge: Sendable, Equatable { case left, right, top, bottom }
    public enum Grip: Sendable, Equatable { case corner(left: Bool, top: Bool), edge(Edge), inside }

    /// How far outside an edge it can be taken (points). Inside, an edge reaches at most a third of the box, so a
    /// small box keeps a middle to move it by.
    public static let reach = 6.0

    /// What a press at (`x`, `y`) takes of the box `r`, or nil (outside it and its edges: a new box is drawn).
    public static func grip(atX x: Double, y: Double, in r: Rect) -> Grip? {
        let inX = min(reach, r.width / 3), inY = min(reach, r.height / 3)
        let withinX = x >= r.minX - reach && x <= r.maxX + reach
        let withinY = y >= r.minY - reach && y <= r.maxY + reach
        guard withinX, withinY else { return nil }
        let left = x <= r.minX + inX, right = x >= r.maxX - inX
        let top = y <= r.minY + inY, bottom = y >= r.maxY - inY
        let horizontal: Edge? = left && right ? (x - r.minX <= r.maxX - x ? .left : .right) : left ? .left : right ? .right : nil
        let vertical: Edge? = top && bottom ? (y - r.minY <= r.maxY - y ? .top : .bottom) : top ? .top : bottom ? .bottom : nil
        switch (horizontal, vertical) {
        case let (h?, v?): return .corner(left: h == .left, top: v == .top)
        case let (h?, nil): return .edge(h)
        case let (nil, v?): return .edge(v)
        case (nil, nil): return .inside
        }
    }

    /// The box `r` after `grip` was dragged by (`dx`, `dy`). Sides that cross change places, so the box is always
    /// the right way round.
    public static func drag(_ grip: Grip, _ r: Rect, dx: Double, dy: Double) -> Rect {
        var a = (minX: r.minX, minY: r.minY, maxX: r.maxX, maxY: r.maxY)
        switch grip {
        case .inside:
            a.minX += dx; a.maxX += dx; a.minY += dy; a.maxY += dy
        case .edge(.left): a.minX += dx
        case .edge(.right): a.maxX += dx
        case .edge(.top): a.minY += dy
        case .edge(.bottom): a.maxY += dy
        case .corner(let left, let top):
            if left { a.minX += dx } else { a.maxX += dx }
            if top { a.minY += dy } else { a.maxY += dy }
        }
        return Rect(minX: a.minX, minY: a.minY, maxX: a.maxX, maxY: a.maxY)
    }

    /// Where the eight handles are drawn: the corners, then the middles of the edges.
    public static func handles(_ r: Rect) -> [(x: Double, y: Double)] {
        let mx = (r.minX + r.maxX) / 2, my = (r.minY + r.maxY) / 2
        return [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY), (mx, r.minY), (mx, r.maxY), (r.minX, my), (r.maxX, my)]
    }
}
