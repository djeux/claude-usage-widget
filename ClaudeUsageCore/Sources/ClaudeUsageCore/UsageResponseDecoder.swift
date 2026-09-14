import Foundation

/// Decodes the /api/oauth/usage response into limit windows.
/// Tolerant by design: null windows and unknown keys are skipped, so API
/// additions don't break the app.
public enum UsageResponseDecoder {
    /// Known top-level window keys in display order.
    /// Adding a window requires three coordinated edits: this array, a field
    /// on `RawResponse`, and an entry in `byKey` inside `decode` — a key
    /// missing from any of them silently never decodes.
    static let knownWindows: [(key: String, label: String)] = [
        ("five_hour", "Session (5h)"),
        ("seven_day", "Week (all models)"),
        ("seven_day_opus", "Week (Opus)"),
        ("seven_day_sonnet", "Week (Sonnet)"),
    ]

    /// Id prefix for windows decoded from `limits[]`; the suffix is the
    /// lowercased model display name, e.g. "weekly_scoped:fable".
    static let scopedIDPrefix = "weekly_scoped:"

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    /// One element of the `limits[]` array. Per-model weekly limits (Fable, …)
    /// appear only here, as `kind == "weekly_scoped"` with a model display
    /// name — there is no top-level key for them. Every field is optional so
    /// an unexpected shape skips the entry, not the whole response.
    private struct RawLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resets_at: RawResetTime?
        let scope: Scope?

        struct Scope: Decodable {
            let model: Model?
        }

        struct Model: Decodable {
            let display_name: String?
        }
    }

    /// `limits[].resets_at` is an ISO-8601 string in captured responses;
    /// Claude Code also accepts epoch seconds, so both are accepted here.
    private enum RawResetTime: Decodable {
        case iso(String)
        case epochSeconds(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .iso(string)
            } else {
                self = .epochSeconds(try container.decode(Double.self))
            }
        }

        var date: Date? {
            switch self {
            case .iso(let string): return ISO8601.parse(string)
            case .epochSeconds(let seconds): return Date(timeIntervalSince1970: seconds)
            }
        }
    }

    /// Decodes to nil instead of throwing, so one malformed element (or a
    /// wrongly typed field) doesn't fail the container around it.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct RawResponse: Decodable {
        let five_hour: RawWindow?
        let seven_day: RawWindow?
        let seven_day_opus: RawWindow?
        let seven_day_sonnet: RawWindow?
        let limits: Lenient<[Lenient<RawLimit>]>?
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
        for limit in raw.limits?.value?.compactMap(\.value) ?? [] {
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.display_name, !name.isEmpty,
                  let utilization = limit.percent,
                  let resetsAt = limit.resets_at?.date
            else { continue }
            let label = "Week (\(name))"
            // A scoped Opus/Sonnet entry duplicates the top-level key when both are sent.
            guard !windows.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame })
            else { continue }
            windows.append(LimitWindow(id: scopedIDPrefix + name.lowercased(), label: label,
                                       utilization: utilization, resetsAt: resetsAt))
        }
        return UsageSnapshot(windows: windows)
    }
}
