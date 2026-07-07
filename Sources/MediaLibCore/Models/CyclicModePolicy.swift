public enum CyclicModePolicy {
    public static func next<Mode: Equatable, Modes: Collection>(
        after current: Mode,
        in modes: Modes
    ) -> Mode where Modes.Element == Mode {
        guard let first = modes.first else {
            return current
        }
        guard let index = modes.firstIndex(of: current) else {
            return first
        }
        let nextIndex = modes.index(after: index)
        return nextIndex == modes.endIndex ? first : modes[nextIndex]
    }

    public static func previous<Mode: Equatable, Modes: BidirectionalCollection>(
        after current: Mode,
        in modes: Modes
    ) -> Mode where Modes.Element == Mode {
        guard let first = modes.first else {
            return current
        }
        guard let index = modes.firstIndex(of: current) else {
            return first
        }
        if index == modes.startIndex {
            return modes[modes.index(before: modes.endIndex)]
        }
        return modes[modes.index(before: index)]
    }
}
