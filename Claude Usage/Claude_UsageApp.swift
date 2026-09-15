import SwiftUI
import ClaudeUsageCore

@main
struct Claude_UsageApp: App {
    @StateObject private var viewModel = UsageViewModel(
        credentials: OAuthCredentialsStore(store: KeychainTokenStore(), tokens: OAuthTokenClient()),
        fetcher: UsageClient(),
        openURL: { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
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
