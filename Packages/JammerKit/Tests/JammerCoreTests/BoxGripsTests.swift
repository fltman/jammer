import Testing
@testable import JammerCore

@Suite("A drawn box's grips: corners and edges resize it, the inside moves it")
struct BoxGripsTests {
    let box = BoxGrips.Rect(minX: 100, minY: 50, maxX: 300, maxY: 150)

    @Test("Each zone takes what it shows: corners, edges a little inside and outside, the middle, and nothing beyond")
    func zones() {
        func g(_ x: Double, _ y: Double) -> BoxGrips.Grip? { BoxGrips.grip(atX: x, y: y, in: box) }
        #expect(g(100, 50) == .corner(left: true, top: true))
        #expect(g(304, 153) == .corner(left: false, top: false), "just outside a corner still takes it")
        #expect(g(98, 100) == .edge(.left) && g(105, 100) == .edge(.left))
        #expect(g(300, 100) == .edge(.right))
        #expect(g(200, 47) == .edge(.top) && g(200, 155) == .edge(.bottom))
        #expect(g(200, 100) == .inside)
        #expect(g(93, 100) == nil && g(200, 157) == nil && g(400, 100) == nil, "beyond the reach: a new box")
    }

    @Test("A small box keeps a middle to move it by, and its nearer edge is the one taken")
    func smallBox() {
        let small = BoxGrips.Rect(minX: 0, minY: 0, maxX: 9, maxY: 9)
        #expect(BoxGrips.grip(atX: 4.5, y: 4.5, in: small) == .inside)
        #expect(BoxGrips.grip(atX: 1, y: 4.5, in: small) == .edge(.left))
        #expect(BoxGrips.grip(atX: 8, y: 4.5, in: small) == .edge(.right))
        let thin = BoxGrips.Rect(minX: 0, minY: 0, maxX: 2, maxY: 100)
        #expect(BoxGrips.grip(atX: 0.4, y: 50, in: thin) == .edge(.left) && BoxGrips.grip(atX: 1.6, y: 50, in: thin) == .edge(.right))
    }

    @Test("Dragging: an edge moves one side, a corner two, the inside all four; sides that cross change places")
    func drag() {
        #expect(BoxGrips.drag(.edge(.left), box, dx: 20, dy: 99) == .init(minX: 120, minY: 50, maxX: 300, maxY: 150))
        #expect(BoxGrips.drag(.edge(.bottom), box, dx: 99, dy: -30) == .init(minX: 100, minY: 50, maxX: 300, maxY: 120))
        #expect(BoxGrips.drag(.corner(left: false, top: true), box, dx: 10, dy: -10) == .init(minX: 100, minY: 40, maxX: 310, maxY: 150))
        #expect(BoxGrips.drag(.inside, box, dx: -50, dy: 25) == .init(minX: 50, minY: 75, maxX: 250, maxY: 175))
        let crossed = BoxGrips.drag(.edge(.left), box, dx: 250, dy: 0)
        #expect(crossed.minX == 300 && crossed.maxX == 350, "the left side dragged past the right: the box is the right way round")
        #expect(BoxGrips.handles(box).count == 8)
    }
}
