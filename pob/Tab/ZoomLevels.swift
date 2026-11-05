enum ZoomLevels {
    static let steps: [Double] = [0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2]

    /// The next step above `zoom`, or the top step.
    static func larger(than zoom: Double) -> Double {
        steps.first { $0 > zoom + 0.0001 } ?? steps[steps.count - 1]
    }

    /// The next step below `zoom`, or the bottom step.
    static func smaller(than zoom: Double) -> Double {
        steps.last { $0 < zoom - 0.0001 } ?? steps[0]
    }
}
