import SwiftUI
import ClaudeUsageCore

@main
struct Claude_UsageApp: App {
    @StateObject private var viewModel = UsageViewModel(
        credentials: KeychainCredentialsStore(),
        fetcher: UsageClient()
    )

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
                .onAppear { viewModel.startAutoRefresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
