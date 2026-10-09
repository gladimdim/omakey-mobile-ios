/// How portrait mode's upper key row changes when a key is dropped on it.
public enum StripSlots {
    /// Drop [key], dragged from slot [from] (or -1 for the pages), on slot [to]
    /// (or -1 for off the row). A key in the way swaps places with it, so the
    /// row never holds a key twice; one dragged off the row leaves its slot empty.
    public static func drop<T: Equatable>(_ slots: inout [T?], _ key: T, from: Int, to: Int) {
        if to < 0 {
            if from >= 0 { slots[from] = nil }
            return
        }
        // From the pages but already in the row: moved from where it is.
        let src = from >= 0 ? from : slots.firstIndex(of: key) ?? -1
        let displaced = slots[to]
        slots[to] = key
        if src >= 0 && src != to { slots[src] = displaced }
    }
}
