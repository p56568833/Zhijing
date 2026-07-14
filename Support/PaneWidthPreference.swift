import Foundation

enum PaneWidthPreference {
    static func load(
        key: String,
        default defaultValue: Double,
        range: ClosedRange<Double>,
        defaults: UserDefaults = .standard
    ) -> Double {
        clamped(
            defaults.object(forKey: key) as? Double,
            default: defaultValue,
            range: range
        )
    }

    static func clamped(
        _ value: Double?,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard let value, value.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
