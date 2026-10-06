import Foundation

public enum UnitSystem: String, Codable, CaseIterable, Sendable, Identifiable {
    case imperial, metric

    public var id: String { rawValue }
    public var speedUnit: String { self == .imperial ? "mph" : "km/h" }
    public var distanceUnit: String { self == .imperial ? "mi" : "km" }

    /// m/s → display speed.
    public func speed(_ mps: Double) -> Double { self == .imperial ? mps * 2.236_936 : mps * 3.6 }
    /// display speed → m/s.
    public func metersPerSecond(_ value: Double) -> Double { self == .imperial ? value / 2.236_936 : value / 3.6 }
    /// meters → display distance.
    public func distance(_ m: Double) -> Double { self == .imperial ? m / 1_609.344 : m / 1_000 }
}

public enum Format {
    public static func speed(_ mps: Double?, _ units: UnitSystem, unit: Bool = false) -> String {
        guard let mps, mps.isFinite else { return "--" }
        let v = String(format: "%.0f", units.speed(mps))
        return unit ? "\(v) \(units.speedUnit)" : v
    }

    public static func distance(_ m: Double?, _ units: UnitSystem, unit: Bool = true) -> String {
        guard let m, m.isFinite else { return "--" }
        let d = units.distance(m)
        let v = abs(d) < 10 ? String(format: "%.1f", d) : String(format: "%.0f", d)
        return unit ? "\(v) \(units.distanceUnit)" : v
    }

    /// Durations as H:MM:SS (or M:SS under an hour). Negative values get a sign.
    public static func duration(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "--:--" }
        let total = Int(abs(t).rounded())
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        let sign = t < 0 ? "-" : ""
        return h > 0
            ? sign + String(format: "%d:%02d:%02d", h, m, s)
            : sign + String(format: "%d:%02d", m, s)
    }

    /// Early/late delta, aviation style: "+2:15" late, "-0:40" early.
    public static func delta(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "" }
        if abs(t) < 0.5 { return "±0:00" }
        return (t > 0 ? "+" : "") + duration(t)
    }

    /// Clock time "14:05:09" in the given time zone.
    public static func clock(_ date: Date?, seconds: Bool = true, timeZone: TimeZone = .current) -> String {
        guard let date else { return "--:--" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        return seconds
            ? String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            : String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
