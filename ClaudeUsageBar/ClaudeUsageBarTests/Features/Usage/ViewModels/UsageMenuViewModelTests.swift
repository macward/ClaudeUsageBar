import Foundation
import Testing
@testable import ClaudeUsageBar

@MainActor
@Suite("UsageMenuViewModel")
struct UsageMenuViewModelTests {

    @Test("Without the onboarding flag, initial state is .onboarding and nothing was fetched")
    func initialStateIsOnboardingWithoutFlag() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 42))])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        #expect(viewModel.state == .onboarding)
        #expect(apiService.callCount == 0)
    }

    @Test("completeOnboarding() transitions out of onboarding and performs a fetch")
    func completeOnboardingStartsFetch() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 42))])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        viewModel.completeOnboarding()
        #expect(viewModel.state == .loading)

        // With polling disabled there's no background loop to drive the fetch — the test
        // triggers it explicitly, same as a real caller would via a manual refresh trigger.
        await viewModel.refresh()

        guard case .fresh(let detail) = viewModel.state else {
            Issue.record("expected .fresh, got \(viewModel.state)"); return
        }
        #expect(detail.dominant.percentUsed == 42)
        #expect(defaults.bool(forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding") == true)
    }

    @Test("A refresh() made before the repository's throttle deadline never touches the API service again")
    func refreshRespectsThrottleWithoutExtraCalls() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()
        #expect(apiService.callCount == 1)

        await viewModel.refresh()

        #expect(apiService.callCount == 1)
        guard case .throttled = viewModel.state else {
            Issue.record("expected .throttled, got \(viewModel.state)"); return
        }
    }

    @Test("A stale repository result maps to .stale with its age")
    func staleRepositoryResultMapsToStaleState() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        Self.seedCache(defaults, snapshot: Self.sampleSnapshot(percent: 55), fetchedAt: Date().addingTimeInterval(-11 * 60))
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.failure(.offline)])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()

        guard case .stale(let detail, let age) = viewModel.state else {
            Issue.record("expected .stale, got \(viewModel.state)"); return
        }
        #expect(detail.dominant.percentUsed == 55)
        #expect(abs(age - 11 * 60) < 1)
    }

    @Test("Severity thresholds change exactly at 70 and 90, not one point earlier or later", arguments: [
        (69, UsageDisplayState.Severity.normal),
        (70, UsageDisplayState.Severity.warning),
        (89, UsageDisplayState.Severity.warning),
        (90, UsageDisplayState.Severity.critical)
    ])
    func severityThresholdsChangeExactlyAt70And90(percent: Int, expectedSeverity: UsageDisplayState.Severity) async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [
            .success(Self.sampleSnapshot(percent: Double(percent)))
        ])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()

        guard case .fresh(let detail) = viewModel.state else {
            Issue.record("expected .fresh, got \(viewModel.state)"); return
        }
        #expect(detail.dominant.severity == expectedSeverity)
    }

    @Test("Among five_hour, seven_day, and active limits, the highest-usage window wins as dominant")
    func dominantWindowIsTheHighestUsageOne() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let snapshot: UsageSnapshot = UsageSnapshot(
            fiveHour: UsageSnapshot.Window(utilization: 20, resetsAt: Date().addingTimeInterval(3600)),
            sevenDay: UsageSnapshot.Window(utilization: 85, resetsAt: Date().addingTimeInterval(86400)),
            limits: nil
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(snapshot)])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()

        guard case .fresh(let detail) = viewModel.state else {
            Issue.record("expected .fresh, got \(viewModel.state)"); return
        }
        #expect(detail.dominant.windowKind == "seven_day")
        #expect(detail.dominant.percentUsed == 85)
        #expect(detail.fiveHour?.percentUsed == 20)
        #expect(detail.sevenDay?.percentUsed == 85)
    }

    @Test("A network error maps to a distinct .error(.repository(.offline)) state, not a generic error")
    func networkErrorMapsToDistinctOfflineState() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.failure(.offline)])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()

        #expect(viewModel.state == .error(.repository(.offline)))
    }

    @Test("Deallocating the ViewModel cancels its polling loop cleanly — no further fetches occur")
    func deinitCancelsPollingLoopCleanly() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        var viewModel: UsageMenuViewModel? = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: true,
            userDefaults: defaults
        )

        // Let the polling loop's first iteration run to completion — it calls refresh()
        // immediately, then suspends in Task.sleep(for: ~180s) waiting for the next deadline.
        try await Task.sleep(for: .milliseconds(100))
        #expect(apiService.callCount == 1)

        viewModel = nil // triggers isolated deinit -> pollingTask.cancel()
        _ = viewModel

        try await Task.sleep(for: .milliseconds(100))
        #expect(apiService.callCount == 1)
    }

    @Test("refreshOnPopoverOpen skips fetching when the displayed snapshot is within the freshness TTL")
    func refreshOnPopoverOpenSkipsWhenSnapshotIsFresh() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )
        await viewModel.refresh()
        #expect(apiService.callCount == 1)

        await viewModel.refreshOnPopoverOpen()

        #expect(apiService.callCount == 1)
    }

    @Test("refreshOnPopoverOpen calls through to the repository once the displayed snapshot exceeds the freshness TTL")
    func refreshOnPopoverOpenFetchesWhenSnapshotIsStale() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        Self.seedCache(defaults, snapshot: Self.sampleSnapshot(percent: 10), fetchedAt: Date().addingTimeInterval(-700))
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.failure(.offline)])
        let repository: UsageRepository = Self.makeRepository(apiService: apiService, defaults: defaults)
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )
        await viewModel.refresh()
        guard case .stale = viewModel.state else { Issue.record("expected .stale, got \(viewModel.state)"); return }
        #expect(apiService.callCount == 1)

        await viewModel.refreshOnPopoverOpen()

        // The ViewModel's own TTL gate let the call through to the repository — proven by the
        // state changing to .throttled, which only the repository (not the ViewModel) can
        // produce. The repository's own 180s post-attempt throttle is a separate, already
        // covered concern (see UsageRepositoryTests), which is why callCount stays at 1 here.
        guard case .throttled = viewModel.state else { Issue.record("expected .throttled, got \(viewModel.state)"); return }
    }

    @Test("Before onboarding completes, neither the Keychain nor the network is touched — even with polling on")
    func onboardingGateBlocksKeychainAndNetwork() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.success(Self.validCredentials())]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: true,
            userDefaults: defaults
        )

        // A popover opened during onboarding must not become an implicit authorization either.
        await viewModel.refreshOnPopoverOpen()
        await viewModel.refresh()
        try await Task.sleep(for: .milliseconds(200))

        #expect(viewModel.state == .onboarding)
        #expect(credentialsService.callCount == 0)
        #expect(apiService.callCount == 0)

        viewModel.completeOnboarding()
        await viewModel.refresh()

        #expect(credentialsService.callCount >= 1)
        guard case .fresh = viewModel.state else {
            Issue.record("expected .fresh after authorizing, got \(viewModel.state)"); return
        }
    }

    @Test("A denied Keychain read stops the polling loop so the app never re-prompts on its own")
    func deniedKeychainAccessSuspendsPolling() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.failure(.userDeniedAccess)]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: true,
            userDefaults: defaults
        )

        // Long enough for the loop's first iteration to fail and, without the suspension, to come
        // back around: a credentials failure never moves the repository's throttle deadline, so
        // the loop's own sleep would be the 1s floor.
        try await Task.sleep(for: .milliseconds(1500))

        #expect(credentialsService.callCount == 1)
        #expect(viewModel.isAwaitingAuthorizationRetry == true)
        #expect(viewModel.state == .error(.repository(.credentialsUnavailable(.userDeniedAccess))))
    }

    @Test("After a denial, opening the popover does not re-read the Keychain — only Reintentar may re-prompt")
    func popoverOpenAfterDenialDoesNotRePrompt() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.failure(.userDeniedAccess)]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )
        await viewModel.refresh()
        #expect(credentialsService.callCount == 1)

        // No successful fetch ever landed, so the freshness TTL gate cannot be what stops this —
        // the denial gate has to.
        await viewModel.refreshOnPopoverOpen()
        await viewModel.refresh()

        #expect(credentialsService.callCount == 1)
        #expect(viewModel.isAwaitingAuthorizationRetry == true)
    }

    @Test("An error that is not an authorization failure leaves the polling loop running")
    func nonAuthorizationErrorDoesNotSuspendPolling() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.failure(.itemNotFound)]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()

        #expect(viewModel.isAwaitingAuthorizationRetry == false)
        #expect(viewModel.state == .error(.repository(.credentialsUnavailable(.itemNotFound))))
    }

    @Test("retryAuthorization() re-reads the Keychain once and recovers when access is granted")
    func retryAuthorizationRecoversAfterGrant() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.failure(.userDeniedAccess), .success(Self.validCredentials())]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 33))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.refresh()
        #expect(viewModel.isAwaitingAuthorizationRetry == true)

        await viewModel.retryAuthorization()

        #expect(credentialsService.callCount == 2)
        #expect(viewModel.isAwaitingAuthorizationRetry == false)
        guard case .fresh(let detail) = viewModel.state else {
            Issue.record("expected .fresh, got \(viewModel.state)"); return
        }
        #expect(detail.dominant.percentUsed == 33)
    }

    @Test("retryAuthorization() stays in the denied state when access is refused again")
    func retryAuthorizationKeepsGateAfterSecondDenial() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        defaults.set(true, forKey: "com.maxward.ClaudeUsageBar.hasCompletedOnboarding")
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.failure(.userDeniedAccess)]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )
        await viewModel.refresh()

        await viewModel.retryAuthorization()

        #expect(credentialsService.callCount == 2)
        #expect(viewModel.isAwaitingAuthorizationRetry == true)
        #expect(viewModel.state == .error(.repository(.credentialsUnavailable(.userDeniedAccess))))
    }

    @Test("retryAuthorization() does nothing when the app is not waiting on an authorization retry")
    func retryAuthorizationIsNoOpWithoutDenial() async throws {
        let defaults: UserDefaults = Self.freshDefaults()
        let credentialsService: SequencedCredentialsService = SequencedCredentialsService(
            results: [.success(Self.validCredentials())]
        )
        let apiService: SequencedUsageAPIService = SequencedUsageAPIService(results: [.success(Self.sampleSnapshot(percent: 10))])
        let repository: UsageRepository = UsageRepository(
            credentialsService: credentialsService,
            apiService: apiService,
            userDefaults: defaults
        )
        let viewModel: UsageMenuViewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: false,
            userDefaults: defaults
        )

        await viewModel.retryAuthorization()

        #expect(credentialsService.callCount == 0)
        #expect(viewModel.state == .onboarding)
    }

    // MARK: - Private Helpers

    private static func freshDefaults() -> UserDefaults {
        let suiteName: String = "com.maxward.ClaudeUsageBarTests.\(UUID().uuidString)"
        let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func makeRepository(apiService: SequencedUsageAPIService, defaults: UserDefaults) -> UsageRepository {
        UsageRepository(
            credentialsService: MockClaudeCodeCredentialsService(result: .success(Self.validCredentials())),
            apiService: apiService,
            userDefaults: defaults
        )
    }

    private static func validCredentials() -> ClaudeCodeCredentials {
        ClaudeCodeCredentials(
            accessToken: "sk-ant-oat01-token",
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: "max",
            scopes: []
        )
    }

    private static func sampleSnapshot(percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageSnapshot.Window(utilization: percent, resetsAt: Date().addingTimeInterval(3600)),
            sevenDay: nil,
            limits: nil
        )
    }

    private static func seedCache(_ defaults: UserDefaults, snapshot: UsageSnapshot, fetchedAt: Date) {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        struct CachedUsage: Codable {
            let snapshot: UsageSnapshot
            let fetchedAt: Date
        }
        let data: Data = try! encoder.encode(CachedUsage(snapshot: snapshot, fetchedAt: fetchedAt))
        defaults.set(data, forKey: "com.maxward.ClaudeUsageBar.cachedUsageSnapshot")
    }
}
