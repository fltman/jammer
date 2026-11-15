import Foundation
import Testing
@testable import JammerCore

@Suite("Undo steps")
@MainActor
struct UndoStepTests {
    final class Box { var value = 0 }

    func set(_ box: Box, _ v: Int, _ um: UndoManager) {
        let old = box.value
        box.value = v
        um.registerUndo(withTarget: box) { [weak um] b in if let um { MainActor.assumeIsolated { set(b, old, um) } } }
    }

    @Test("Three steps without events are three undo steps; undo and redo don't throw")
    func separate() {
        let um = UndoManager()
        #expect(um.groupsByEvent)
        let box = Box()
        for v in 1...3 { um.separateStep { set(box, v, um) } }
        #expect(um.groupingLevel == 0 && um.groupsByEvent)
        um.undo(); #expect(box.value == 2)
        um.undo(); #expect(box.value == 1)
        um.redo(); #expect(box.value == 2)
        // A run-loop pass (where AppKit would close automatic groups) changes nothing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        um.undo(); #expect(box.value == 1)
        um.undo(); #expect(box.value == 0)
        #expect(!um.canUndo)
    }

    @Test("Inside an open group (a user event) the step joins it")
    func inGroup() {
        let um = UndoManager()
        um.groupsByEvent = false
        let box = Box()
        um.beginUndoGrouping()
        um.separateStep { set(box, 1, um) }
        um.separateStep { set(box, 2, um) }
        um.endUndoGrouping()
        um.undo()
        #expect(box.value == 0)
    }
}
