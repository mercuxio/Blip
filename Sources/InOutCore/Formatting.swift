import Foundation

/// Byte formatting tuned for a menu bar: short, stable in width, and using the
/// decimal units Apple's own UI uses (Activity Monitor, Finder), not binary.
public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// e.g. `1.2 MB/s`, `48 KB/s`, `0 B/s`
    public static func rate(_ bytesPerSecond: Double) -> String {
        scaled(bytesPerSecond) + "/s"
    }

    /// e.g. `4.7 GB`, `812 MB`
    public static func total(_ bytes: UInt64) -> String {
        scaled(Double(bytes))
    }

    /// Value + unit, one decimal below 10 so the reading stays legible without
    /// the string length jittering every tick.
    public static func scaled(_ value: Double) -> String {
        guard value.isFinite, value >= 1 else { return "0 B" }

        var magnitude = value
        var index = 0
        while magnitude >= 1000, index < units.count - 1 {
            magnitude /= 1000
            index += 1
        }

        let digits = (magnitude < 10 && index > 0) ? 1 : 0
        return String(format: "%.\(digits)f %@", magnitude, units[index])
    }
}
