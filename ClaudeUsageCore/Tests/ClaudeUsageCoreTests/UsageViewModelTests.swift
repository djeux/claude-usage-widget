import XCTest
@testable import ClaudeUsageCore

@MainActor
final class UsageViewModelTests: XCTestCase {
    struct FakeCredentials: CredentialsProviding {
        var result: Result<Credentials, CredentialsError>
        func read(now: Date) throws -> Credentials { try result.get() }
    }

    struct FakeFetcher: UsageFetching {
        var result: Result<UsageSnapshot, UsageError>
        func fetch(accessToken: String) async throws -> UsageSnapshot { try result.get() }
    }

    static let now = Date(timeIntervalSince1970: 1_781_179_200)
    static let validCredentials = Credentials(accessToken: "sk-test",
                                              expiresAt: now.addingTimeInterval(3600))
    static let snapshot = UsageSnapshot(windows: [
        LimitWindow(id: "five_hour", label: "Session (5h)", utilization: 62,
                    resetsAt: now.addingTimeInterval(8040)),
        LimitWindow(id: "seven_day", label: "Week (all models)", utilization: 31,
                    resetsAt: now.addingTimeInterval(100_000)),
    ])

    private func makeViewModel(
        credentials: Result<Credentials, CredentialsError> = .success(UsageViewModelTests.validCredentials),
        fetch: Result<UsageSnapshot, UsageError> = .success(UsageViewModelTests.snapshot)
    ) -> UsageViewModel {
        UsageViewModel(credentials: FakeCredentials(result: credentials),
                       fetcher: FakeFetcher(result: fetch),
                       now: { Self.now })
    }

    func testSuccessfulRefresh() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
        XCTAssertEqual(viewModel.fetchedAt, Self.now)
    }

    func testMostConstrainedPicksHighestUtilization() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.mostConstrained?.id, "five_hour")
    }

    func testMostConstrainedIsNilWithoutData() {
        XCTAssertNil(makeViewModel().mostConstrained)
    }

    func testNotLoggedIn() async {
        let viewModel = makeViewModel(credentials: .failure(.notLoggedIn))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Claude Code not logged in"))
    }

    func testExpiredToken() async {
        let viewModel = makeViewModel(credentials: .failure(.expired))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Token expired — open Claude Code to refresh"))
    }

    func testAccessDenied() async {
        let viewModel = makeViewModel(credentials: .failure(.accessDenied))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Keychain access denied — re-allow in prompt"))
    }

    func testUnauthorizedFetch() async {
        let viewModel = makeViewModel(fetch: .failure(.unauthorized))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Token rejected — open Claude Code to refresh"))
    }

    func testNetworkErrorKeepsLastSnapshot() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)

        let failing = FakeFetcher(result: .failure(.http(503)))
        viewModel.setFetcherForTesting(failing)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        XCTAssertEqual(viewModel.snapshot, Self.snapshot) // last good data preserved
    }

    func testRecoversFromDegradedOnNextRefresh() async {
        let viewModel = makeViewModel(fetch: .failure(.http(503)))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))

        viewModel.setFetcherForTesting(FakeFetcher(result: .success(Self.snapshot)))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }
}
