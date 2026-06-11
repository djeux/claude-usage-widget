import Foundation

/// Decodes the /api/oauth/usage response into limit windows.
/// Tolerant by design: null windows and unknown keys are skipped, so API
/// additions don't break the app.
public enum UsageResponseDecoder {
    /// Known window keys in display order.
    /// Adding a window requires three coordinated edits: this array, a field
    /// on `RawResponse`, and an entry in `byKey` inside `decode` — a key
    /// missing from any of them silently never decodes.
    static let knownWindows: [(key: String, label: String)] = [
        ("five_hour", "Session (5h)"),
        ("seven_day", "Week (all models)"),
        ("seven_day_opus", "Week (Opus)"),
        ("seven_day_sonnet", "Week (Sonnet)"),
    ]

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    private struct RawResponse: Decodable {
        let five_hour: RawWindow?
        let seven_day: RawWindow?
        let seven_day_opus: RawWindow?
        let seven_day_sonnet: RawWindow?
    }

    public static func decode(_ data: Data) throws -> UsageSnapshot {
        let raw = try JSONDecoder().decode(RawResponse.self, from: data)
        let byKey: [String: RawWindow?] = [
            "five_hour": raw.five_hour,
            "seven_day": raw.seven_day,
            "seven_day_opus": raw.seven_day_opus,
            "seven_day_sonnet": raw.seven_day_sonnet,
        ]
        var windows: [LimitWindow] = []
        for (key, label) in knownWindows {
            guard let rawWindow = byKey[key] ?? nil,
                  let utilization = rawWindow.utilization,
                  let resetString = rawWindow.resets_at,
                  let resetsAt = ISO8601.parse(resetString)
            else { continue }
            windows.append(LimitWindow(id: key, label: label,
                                       utilization: utilization, resetsAt: resetsAt))
        }
        return UsageSnapshot(windows: windows)
    }
}
