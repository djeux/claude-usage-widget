import Foundation

/// Parses the API's ISO-8601 timestamps, which carry microsecond fractions
/// that `ISO8601DateFormatter` cannot handle directly.
public enum ISO8601 {
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    public static func parse(_ string: String) -> Date? {
        let trimmed = trimFractionToMilliseconds(string)
        return makeFormatter(fractional: true).date(from: trimmed)
            ?? makeFormatter(fractional: false).date(from: trimmed)
    }

    /// "…00.170987+00:00" → "…00.170+00:00"; strings without a fraction pass through.
    static func trimFractionToMilliseconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let fractionStart = string.index(after: dot)
        var fractionEnd = fractionStart
        while fractionEnd < string.endIndex, string[fractionEnd].isNumber {
            fractionEnd = string.index(after: fractionEnd)
        }
        let fraction = string[fractionStart..<fractionEnd].prefix(3)
        guard !fraction.isEmpty else {
            return String(string[..<dot]) + String(string[fractionEnd...])
        }
        return String(string[..<fractionStart]) + fraction + String(string[fractionEnd...])
    }
}
