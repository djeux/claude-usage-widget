import Foundation

/// One rolling rate-limit window as reported by the usage endpoint.
public struct LimitWindow: Equatable, Identifiable, Sendable {
    /// API field name, e.g. "five_hour".
    public let id: String
    /// Display label, e.g. "Session (5h)".
    public let label: String
    /// Percentage 0–100 (the API reports percent, not a fraction).
    public let utilization: Double
    public let resetsAt: Date

    public init(id: String, label: String, utilization: Double, resetsAt: Date) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let windows: [LimitWindow]

    public init(windows: [LimitWindow]) {
        self.windows = windows
    }
}

public enum Severity: Equatable, Sendable {
    case normal
    case warning
    case critical

    public static func forUtilization(_ utilization: Double) -> Severity {
        if utilization >= 95 { return .critical }
        if utilization >= 60 { return .warning }
        return .normal
    }
}
