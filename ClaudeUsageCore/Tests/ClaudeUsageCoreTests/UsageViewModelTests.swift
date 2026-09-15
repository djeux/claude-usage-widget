import XCTest
@testable import ClaudeUsageCore

@MainActor
final class UsageViewModelTests: XCTestCase {
    final class FakeSession: SessionManaging, @unchecked Sendable {
        var readResults: [Result<Credentials, CredentialsError>]
        var signInResult: Result<Void, SignInError> = .success(())
        var readCount = 0, invalidateCount = 0, signOutCount = 0
        var openedURLs: [URL] = []

        init(_ results: [Result<Credentials, CredentialsError>]) { readResults = results }

        func read(now: Date) async throws -> Credentials {
            readCount += 1
            let result = readResults.count > 1 ? readResults.removeFirst() : readResults[0]
            return try result.get()
        }
        func invalidate() async { invalidateCount += 1 }
        func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
            let url = URL(string: "https://claude.com/cai/oauth/authorize?state=x")!
            openURL(url)
            openedURLs.append(url)
            await Task.yield() // let the view model's `.signingIn` phase be observed
            try signInResult.get()
        }
        func signOut() async { signOutCount += 1 }
    }

    final class FakeFetcher: UsageFetching, @unchecked Sendable {
        var results: [Result<UsageSnapshot, UsageError>]
        var calls = 0
        init(_ results: [Result<UsageSnapshot, UsageError>]) { self.results = results }
        func fetch(accessToken: String) async throws -> UsageSnapshot {
            calls += 1
            let result = results.count > 1 ? results.removeFirst() : results[0]
            return try result.get()
        }
    }

    final class URLBox: @unchecked Sendable { var urls: [URL] = [] }

    nonisolated static let now = Date(timeIntervalSince1970: 1_781_179_200)
    nonisolated static let validCredentials = Credentials(accessToken: "sk-test", expiresAt: now.addingTimeInterval(3600))
    nonisolated static let snapshot = UsageSnapshot(windows: [
        LimitWindow(id: "five_hour", label: "Session (5h)", utilization: 62, resetsAt: now.addingTimeInterval(8040)),
        LimitWindow(id: "seven_day", label: "Week (all models)", utilization: 31, resetsAt: now.addingTimeInterval(100_000)),
    ])

    private var session = FakeSession([.success(UsageViewModelTests.validCredentials)])
    private var fetcher = FakeFetcher([.success(UsageViewModelTests.snapshot)])
    private let opened = URLBox()

    private func makeViewModel(
        credentials: [Result<Credentials, CredentialsError>] = [.success(UsageViewModelTests.validCredentials)],
        fetch: [Result<UsageSnapshot, UsageError>] = [.success(UsageViewModelTests.snapshot)]
    ) -> UsageViewModel {
        session = FakeSession(credentials)
        fetcher = FakeFetcher(fetch)
        return UsageViewModel(credentials: session, fetcher: fetcher,
                              openURL: { [opened] in opened.urls.append($0) }, now: { Self.now })
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

    func testNotLoggedInIsSignedOut() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertEqual(fetcher.calls, 0)
    }

    func testRefreshFailedKeepsSnapshotAndDegrades() async {
        let viewModel = makeViewModel(credentials: [.success(Self.validCredentials), .failure(.refreshFailed)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testAccessDenied() async {
        let viewModel = makeViewModel(credentials: [.failure(.accessDenied)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Keychain access denied — re-allow in prompt"))
    }

    func testUnauthorizedRetriesOnceAfterInvalidate() async {
        let viewModel = makeViewModel(fetch: [.failure(.unauthorized), .success(Self.snapshot)])
        await viewModel.refresh()
        XCTAssertEqual(session.invalidateCount, 1)
        XCTAssertEqual(session.readCount, 2)
        XCTAssertEqual(fetcher.calls, 2)
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testSecondUnauthorizedSignsOut() async {
        let viewModel = makeViewModel(fetch: [.failure(.unauthorized), .failure(.unauthorized)])
        await viewModel.refresh()
        XCTAssertEqual(session.invalidateCount, 1)
        XCTAssertEqual(session.signOutCount, 1)
        XCTAssertEqual(fetcher.calls, 2)
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertEqual(viewModel.signInError, "Anthropic rejected the token — sign in again")
    }

    func testNetworkErrorKeepsLastSnapshot() async {
        let viewModel = makeViewModel(fetch: [.success(Self.snapshot), .failure(.http(503))])
        await viewModel.refresh()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testRecoversFromDegradedOnNextRefresh() async {
        let viewModel = makeViewModel(fetch: [.failure(.http(503)), .success(Self.snapshot)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .degraded("Couldn't reach Anthropic"))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
    }

    func testSignInSuccessOpensBrowserThenLoads() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn), .success(Self.validCredentials)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.phase, .signedOut)
        await viewModel.signIn()
        XCTAssertEqual(opened.urls.first?.host, "claude.com")
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.snapshot, Self.snapshot)
        XCTAssertNil(viewModel.signInError)
    }

    func testSignInFailureShowsMessage() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        session.signInResult = .failure(.timedOut)
        await viewModel.signIn()
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertEqual(viewModel.signInError, "Sign-in timed out")
    }

    func testSignInCancelledHasNoMessage() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        session.signInResult = .failure(.cancelled)
        await viewModel.signIn()
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.signInError)
    }

    func testRefreshIsNoOpWhileSigningIn() async {
        let viewModel = makeViewModel(credentials: [.failure(.notLoggedIn)])
        await viewModel.refresh()
        let signInTask = Task { await viewModel.signIn() }
        await Task.yield() // signIn sets `.signingIn` before its first suspension
        XCTAssertEqual(viewModel.phase, .signingIn)
        await viewModel.refresh()
        XCTAssertEqual(session.readCount, 1) // only the initial refresh read
        await signInTask.value
    }

    func testSignOutClearsEverything() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()
        await viewModel.signOut()
        XCTAssertEqual(session.signOutCount, 1)
        XCTAssertEqual(viewModel.phase, .signedOut)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertNil(viewModel.fetchedAt)
    }

    func testSignInMessages() {
        XCTAssertEqual(UsageViewModel.message(for: .listenerFailed), "Couldn't start the local sign-in listener")
        XCTAssertEqual(UsageViewModel.message(for: .denied("access_denied")), "Sign-in was cancelled")
        XCTAssertEqual(UsageViewModel.message(for: .stateMismatch), "Sign-in response didn't match — try again")
        XCTAssertEqual(UsageViewModel.message(for: .timedOut), "Sign-in timed out")
        XCTAssertEqual(UsageViewModel.message(for: .exchangeFailed(.http(502))), "Sign-in failed (HTTP 502)")
        XCTAssertEqual(UsageViewModel.message(for: .exchangeFailed(.network("x"))), "Sign-in failed — couldn't reach Anthropic")
        XCTAssertEqual(UsageViewModel.message(for: .exchangeFailed(.decoding)), "Sign-in failed")
        XCTAssertEqual(UsageViewModel.message(for: .storeFailed), "Couldn't save the login to the keychain")
        XCTAssertNil(UsageViewModel.message(for: .cancelled))
    }
}
