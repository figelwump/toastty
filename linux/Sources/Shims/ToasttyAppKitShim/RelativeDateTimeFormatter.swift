import Foundation

/// Darwin's `RelativeDateTimeFormatter` (absent from corelibs), English
/// output only: "5 min. ago", "in 2 hr.", "3 days ago" (abbreviated) or
/// "5 minutes ago" (full). The largest whole unit wins, like Darwin.
public final class RelativeDateTimeFormatter: @unchecked Sendable {
    public enum UnitsStyle: Sendable {
        case full
        case spellOut
        case short
        case abbreviated
    }

    public enum DateTimeStyle: Sendable {
        case numeric
        case named
    }

    public var unitsStyle: UnitsStyle = .full
    public var dateTimeStyle: DateTimeStyle = .numeric

    public init() {}

    public func localizedString(for date: Date, relativeTo referenceDate: Date) -> String {
        localizedString(fromTimeInterval: date.timeIntervalSince(referenceDate))
    }

    public func localizedString(fromTimeInterval interval: TimeInterval) -> String {
        let magnitude = abs(interval)
        let units: [(seconds: Double, full: String, abbreviated: String, abbreviatedPlural: String)] = [
            (365 * 86_400, "year", "yr.", "yr."),
            (30 * 86_400, "month", "mo.", "mo."),
            (7 * 86_400, "week", "wk.", "wk."),
            (86_400, "day", "day", "days"),
            (3_600, "hour", "hr.", "hr."),
            (60, "minute", "min.", "min."),
            (1, "second", "sec.", "sec."),
        ]
        let unit = units.first { magnitude >= $0.seconds } ?? units[units.count - 1]
        let count = Int(magnitude / unit.seconds)
        if dateTimeStyle == .named, count == 0 {
            return "now"
        }
        let label: String
        switch unitsStyle {
        case .full, .spellOut:
            label = "\(count) \(unit.full)\(count == 1 ? "" : "s")"
        case .short, .abbreviated:
            label = "\(count) \(count == 1 ? unit.abbreviated : unit.abbreviatedPlural)"
        }
        return interval < 0 ? "\(label) ago" : "in \(label)"
    }
}
