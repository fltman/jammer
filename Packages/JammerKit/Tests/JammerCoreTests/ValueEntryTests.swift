import Foundation
import Testing
@testable import JammerCore

@Suite("Values typed beside a slider")
struct ValueEntryTests {
    @Test("A level as people write it: comma or point, the typographic minus, the unit; kept in range")
    func decibels() {
        #expect(ValueEntry.decibels("-3") == -3)
        #expect(ValueEntry.decibels("−3,5 dB") == -3.5)
        #expect(ValueEntry.decibels("+2") == 2)
        #expect(ValueEntry.decibels("40") == 12)
        #expect(ValueEntry.decibels("loud") == nil)
    }

    @Test("A pan: negative or L/V is left, R/H is right, C/M the middle, in percent")
    func pan() {
        #expect(ValueEntry.pan("-30") == -0.3)
        #expect(ValueEntry.pan("L 30") == -0.3 && ValueEntry.pan("V30") == -0.3)
        #expect(ValueEntry.pan("R 25") == 0.25 && ValueEntry.pan("H 25") == 0.25)
        #expect(ValueEntry.pan("C") == 0 && ValueEntry.pan("Mitten") == 0)
        #expect(ValueEntry.pan("150") == 1)
        #expect(ValueEntry.pan("x") == nil)
    }
}
