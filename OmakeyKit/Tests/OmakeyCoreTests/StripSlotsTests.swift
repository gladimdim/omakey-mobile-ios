import Testing
@testable import OmakeyCore

struct StripSlotsTests {
    @Test func fromThePagesIntoAnEmptySlot() {
        var slots: [String?] = [nil, nil, nil]
        StripSlots.drop(&slots, "Esc", from: -1, to: 1)
        #expect(slots == [nil, "Esc", nil])
    }

    @Test func fromThePagesReplacesTheKeyThere() {
        var slots: [String?] = ["Tab", nil, nil]
        StripSlots.drop(&slots, "Esc", from: -1, to: 0)
        #expect(slots == ["Esc", nil, nil])
    }

    @Test func fromThePagesWhenAlreadyInTheRowMovesIt() {
        var slots: [String?] = ["Esc", "Tab", nil]
        StripSlots.drop(&slots, "Esc", from: -1, to: 1)
        #expect(slots == ["Tab", "Esc", nil])
        StripSlots.drop(&slots, "Esc", from: -1, to: 2)
        #expect(slots == ["Tab", nil, "Esc"])
    }

    @Test func alongTheRowSwaps() {
        var slots: [String?] = ["Esc", "Tab", "Del"]
        StripSlots.drop(&slots, "Esc", from: 0, to: 2)
        #expect(slots == ["Del", "Tab", "Esc"])
        StripSlots.drop(&slots, "Tab", from: 1, to: 1)
        #expect(slots == ["Del", "Tab", "Esc"])
    }

    @Test func offTheRowClearsItsSlot() {
        var slots: [String?] = ["Esc", "Tab", nil]
        StripSlots.drop(&slots, "Tab", from: 1, to: -1)
        #expect(slots == ["Esc", nil, nil])
        // From the pages and dropped off the row: nothing changes.
        StripSlots.drop(&slots, "Del", from: -1, to: -1)
        #expect(slots == ["Esc", nil, nil])
    }
}
