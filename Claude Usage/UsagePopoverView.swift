import SwiftUI
import ClaudeUsageCore

struct UsagePopoverView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if case .degraded(let reason) = viewModel.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.snapshot, !snapshot.windows.isEmpty {
            ForEach(snapshot.windows) { window in
                LimitRowView(window: window)
            }
        } else if viewModel.phase == .loading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Text("No limit data reported")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let fetchedAt = viewModel.fetchedAt {
                    Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
            Button("Quit Claude Usage") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
        }
    }
}

struct LimitRowView: View {
    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(window.utilization.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(severityColor)
            }
            .font(.callout)
            ProgressView(value: min(max(window.utilization / 100, 0), 1))
                .tint(severityColor)
            Text(ResetFormatter.string(for: window.resetsAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var severityColor: Color {
        switch Severity.forUtilization(window.utilization) {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
