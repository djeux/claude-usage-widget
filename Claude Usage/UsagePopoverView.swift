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
        switch viewModel.phase {
        case .signedOut:
            signedOutContent
        case .signingIn:
            signingInContent
        default:
            usageContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
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

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in with your Claude account to see usage")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Sign in") {
                Task { await viewModel.signIn() }
            }
            if let error = viewModel.signInError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var signingInContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…")
                    .font(.callout)
            }
            Button("Cancel") {
                viewModel.cancelSignIn()
            }
        }
    }

    private var isSignedIn: Bool {
        switch viewModel.phase {
        case .signedOut, .signingIn: return false
        default: return true
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
                if isSignedIn {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
            HStack {
                if isSignedIn {
                    Button("Sign out") {
                        Task { await viewModel.signOut() }
                    }
                    .font(.caption)
                }
                Spacer()
                Button("Quit Claude Usage") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
            }
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
