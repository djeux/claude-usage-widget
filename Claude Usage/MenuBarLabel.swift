import SwiftUI
import AppKit
import ClaudeUsageCore

struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        if let window = viewModel.mostConstrained {
            let text = "✽ \(Int(window.utilization.rounded()))%"
            label(text: text, severity: Severity.forUtilization(window.utilization))
                .opacity(isDegraded ? 0.5 : 1) // stale data dims regardless of severity
        } else {
            Text("✽ –")
        }
    }

    private var isDegraded: Bool {
        if case .degraded = viewModel.phase { return true }
        return false
    }

    // The menu bar renders plain SwiftUI Text as a template (system color,
    // no tinting), so warning/critical states render into a non-template
    // NSImage via ImageRenderer to get orange/red.
    @ViewBuilder
    private func label(text: String, severity: Severity) -> some View {
        switch severity {
        case .normal:
            Text(text)
        case .warning, .critical:
            Image(nsImage: Self.coloredImage(text: text, severity: severity))
        }
    }

    /// Rendered images are cached: body re-evaluates on every published
    /// change, and rasterizing in that path would be wasted work. Keys are
    /// bounded (percentage text × severity).
    private static var imageCache: [String: NSImage] = [:]

    static func coloredImage(text: String, severity: Severity) -> NSImage {
        let key = "\(text)|\(severity)"
        if let cached = imageCache[key] { return cached }
        let color: Color = severity == .critical ? .red : .orange
        let renderer = ImageRenderer(content:
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
        )
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        imageCache[key] = image
        return image
    }
}
