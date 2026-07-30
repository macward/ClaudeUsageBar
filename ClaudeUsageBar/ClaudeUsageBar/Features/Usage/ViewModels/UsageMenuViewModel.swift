import AppKit
import Foundation
import Observation

/// Everything the menu bar label/popover needs to render — never an `Optional`, always one of
/// these cases. Derived from ``UsageRepositoryResult``, plus the onboarding gate this ViewModel
/// owns on top of it.
internal enum UsageMenuState: Equatable {
    case onboarding
    case loading
    case fresh(UsageDetailData)
    case stale(UsageDetailData, age: TimeInterval)
    case throttled(until: Date)
    case sessionExpired
    case error(UsageMenuError)
}

/// Everything the popover's detail view needs, already resolved — the label only ever needs
/// `dominant`, but the detail view shows both windows plus any active per-limit entries
/// (per-model limits, etc.), all pre-derived here so no threshold/severity logic has to live
/// in the views.
internal struct UsageDetailData: Equatable, Sendable {
    /// The higher-usage window between `fiveHour`/`sevenDay`/active limits — what the menu bar
    /// label shows, since it's the one closest to running out.
    internal let dominant: UsageDisplayState
    internal let fiveHour: UsageDisplayState?
    internal let sevenDay: UsageDisplayState?
    /// Active entries from `limits[]` (e.g. per-model scoped limits) beyond the two named
    /// windows above, already resolved the same way as the named windows so the view never has
    /// to re-derive a severity. Empty, not nil, when the response carries none.
    internal let limits: [UsageDisplayState]
}

internal enum UsageMenuError: Sendable, Equatable, CustomStringConvertible {
    case repository(UsageRepositoryError)
    /// A snapshot arrived, but nothing in it (`five_hour`, `seven_day`, or an active limit)
    /// carried enough data to derive a displayable percentage.
    case noUsableData

    internal var description: String {
        switch self {
        case .repository(let error):
            return error.description
        case .noUsableData:
            return "la respuesta no trae datos de uso utilizables"
        }
    }
}

/// The app's sole ViewModel: owns the polling cycle and the state the views render. Never
/// decides fetch policy itself (that's ``UsageRepository``'s job) — only asks, and reacts to
/// wake/popover-open triggers by asking again.
@Observable
@MainActor
internal final class UsageMenuViewModel {

    private static let onboardingKey: String = "com.maxward.ClaudeUsageBar.hasCompletedOnboarding"

    /// Mirrors the repository's own freshness TTL: a popover-open only triggers a refresh when
    /// the snapshot currently on screen is older than this.
    private static let popoverRefreshTTL: TimeInterval = 600

    internal private(set) var state: UsageMenuState

    /// True while the polling loop is deliberately stopped because the Keychain refused access.
    /// Retrying a denied read re-opens the SecurityAgent prompt, so the loop must never do it on
    /// its own — a denial would otherwise come back as a prompt every cycle. Only
    /// ``retryAuthorization()``, driven by an explicit user action, resumes from here.
    internal private(set) var isAwaitingAuthorizationRetry: Bool = false

    private let repository: UsageRepository
    private let userDefaults: UserDefaults
    private let isPollingEnabled: Bool

    private var pollingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// When the snapshot currently reflected in `state` was actually fetched — reconstructed
    /// from `.fresh`'s implicit "now" or `.stale`'s explicit `age`. `nil` until the first
    /// successful (fresh or stale) result ever lands.
    private var currentSnapshotFetchedAt: Date?

    internal init(repository: UsageRepository, isPollingEnabled: Bool, userDefaults: UserDefaults) {
        self.repository = repository
        self.isPollingEnabled = isPollingEnabled
        self.userDefaults = userDefaults

        if userDefaults.bool(forKey: Self.onboardingKey) {
            self.state = .loading
        } else {
            self.state = .onboarding
        }

        // Onboarding gate: zero activity (no wake subscription, no polling, no Keychain/network
        // touch) until the user has explicitly completed onboarding.
        if case .loading = self.state {
            start()
        }
    }

    isolated deinit {
        pollingTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Public Methods

    internal func completeOnboarding() {
        guard case .onboarding = state else { return }
        userDefaults.set(true, forKey: Self.onboardingKey)
        state = .loading
        start()
    }

    /// The user's explicit "try again" after the Keychain denied access. This is the only path
    /// that may re-trigger the system prompt, and it resumes the polling loop only if the read
    /// actually succeeded this time.
    internal func retryAuthorization() async {
        guard isAwaitingAuthorizationRetry else { return }
        isAwaitingAuthorizationRetry = false
        state = .loading
        await refresh()
        guard !isAwaitingAuthorizationRetry else { return }
        start()
    }

    /// Manual refresh trigger (e.g. a toolbar button). Always defers to the repository's own
    /// throttle decision — never bypasses it.
    /// The guard lives here, not at the call sites: every automatic trigger (polling loop, system
    /// wake, popover open) funnels through this method, so a single check is what actually
    /// enforces "the app never reads the Keychain on its own before onboarding, or after a
    /// denial". `retryAuthorization()` clears the flag before calling in — it is the one
    /// deliberate exception.
    internal func refresh() async {
        guard hasCompletedOnboarding, !isAwaitingAuthorizationRetry else { return }
        let result: UsageRepositoryResult = await repository.refresh()
        apply(result)
    }

    /// Called when the popover is opened. Only asks again if the snapshot currently on screen
    /// is older than the freshness TTL — otherwise leaves the currently displayed state alone.
    internal func refreshOnPopoverOpen() async {
        guard hasCompletedOnboarding else { return }
        if let currentSnapshotFetchedAt, Date().timeIntervalSince(currentSnapshotFetchedAt) < Self.popoverRefreshTTL {
            return
        }
        await refresh()
    }

    // MARK: - Private Methods

    private var hasCompletedOnboarding: Bool {
        userDefaults.bool(forKey: Self.onboardingKey)
    }

    /// `isPollingEnabled` gates ALL background activity, not just the timer loop — with it
    /// false (as in tests), there is no wake subscription either, so a real system sleep/wake
    /// event can never trigger an uncontrolled fetch outside the test's own driving.
    private func start() {
        guard isPollingEnabled else { return }
        subscribeToWake()
        startPollingLoop()
    }

    private func subscribeToWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // The sanctioned exception to the project's "no `Task { @MainActor in }` while already
            // on MainActor" rule: this closure is invoked by NotificationCenter from a
            // non-isolated context, so the hop is what crosses back into this type's isolation,
            // not redundant ceremony.
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    private func startPollingLoop() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard !Task.isCancelled else { return }

                let deadline: Date = self.repository.nextAllowedFetch
                let interval: TimeInterval = max(deadline.timeIntervalSinceNow, 1)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func apply(_ result: UsageRepositoryResult) {
        switch result {
        case .fresh(let snapshot):
            currentSnapshotFetchedAt = Date()
            state = Self.deriveDetailData(from: snapshot).map(UsageMenuState.fresh) ?? .error(.noUsableData)
        case .stale(let snapshot, let age):
            currentSnapshotFetchedAt = Date().addingTimeInterval(-age)
            state = Self.deriveDetailData(from: snapshot).map { .stale($0, age: age) } ?? .error(.noUsableData)
        case .throttled(let until):
            state = .throttled(until: until)
        case .sessionExpired:
            state = .sessionExpired
        case .failure(let error):
            state = .error(.repository(error))
            if case .credentialsUnavailable(let credentialsError) = error, credentialsError.isAuthorizationFailure {
                suspendPollingUntilUserRetries()
            }
        }
    }

    /// Stops the loop in place (this may be called from within the loop's own iteration — the
    /// cancellation is observed at the next `Task.isCancelled` check, which ends it cleanly).
    private func suspendPollingUntilUserRetries() {
        pollingTask?.cancel()
        pollingTask = nil
        // The wake observer has to go too: a sleep/wake cycle would otherwise fire a refresh
        // days later and re-open the system prompt. `start()` re-subscribes on a successful retry.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isAwaitingAuthorizationRetry = true
    }

    /// Resolves everything the popover needs: the dominant window (for the label), the two
    /// named windows individually (for the detail breakdown), and any active per-limit entries.
    /// Returns nil only when nothing in the snapshot carries a usable percentage at all.
    private static func deriveDetailData(from snapshot: UsageSnapshot) -> UsageDetailData? {
        guard let dominant = deriveDisplayState(from: snapshot) else { return nil }

        let fiveHour: UsageDisplayState? = windowDisplayState(kind: "five_hour", window: snapshot.fiveHour)
        let sevenDay: UsageDisplayState? = windowDisplayState(kind: "seven_day", window: snapshot.sevenDay)
        let activeLimits: [UsageDisplayState] = (snapshot.limits ?? [])
            .filter { $0.isActive == true }
            .compactMap(limitDisplayState)

        return UsageDetailData(dominant: dominant, fiveHour: fiveHour, sevenDay: sevenDay, limits: activeLimits)
    }

    /// Picks the higher-usage window between `five_hour`, `seven_day`, and any active entry in
    /// `limits[]` — the "dominant" window is whichever is closest to running out, since that's
    /// the one worth surfacing at a glance. Severity is derived from that percentage directly
    /// (<70 normal, 70–89 warning, ≥90 critical), not trusted from the server's own `severity`
    /// string, so the menu bar's thresholds stay consistent regardless of what the endpoint
    /// reports.
    private static func deriveDisplayState(from snapshot: UsageSnapshot) -> UsageDisplayState? {
        var candidates: [(kind: String, percent: Double, resetsAt: Date)] = []

        if let fiveHour = snapshot.fiveHour, let percent = fiveHour.utilization, let resetsAt = fiveHour.resetsAt {
            candidates.append((kind: "five_hour", percent: percent, resetsAt: resetsAt))
        }
        if let sevenDay = snapshot.sevenDay, let percent = sevenDay.utilization, let resetsAt = sevenDay.resetsAt {
            candidates.append((kind: "seven_day", percent: percent, resetsAt: resetsAt))
        }
        for limit in snapshot.limits ?? [] where limit.isActive == true {
            guard let percent = limit.percent, let resetsAt = limit.resetsAt else { continue }
            candidates.append((kind: limit.kind ?? "unknown", percent: percent, resetsAt: resetsAt))
        }

        guard let dominant = candidates.max(by: { $0.percent < $1.percent }) else { return nil }

        return UsageDisplayState(
            percentUsed: Int(dominant.percent.rounded()),
            severity: severity(forPercent: dominant.percent),
            windowKind: dominant.kind,
            resetsAt: dominant.resetsAt
        )
    }

    private static func limitDisplayState(_ limit: UsageSnapshot.Limit) -> UsageDisplayState? {
        guard let percent = limit.percent, let resetsAt = limit.resetsAt else { return nil }
        return UsageDisplayState(
            percentUsed: Int(percent.rounded()),
            severity: severity(forPercent: percent),
            windowKind: limit.kind ?? "limit",
            resetsAt: resetsAt
        )
    }

    private static func windowDisplayState(kind: String, window: UsageSnapshot.Window?) -> UsageDisplayState? {
        guard let window, let percent = window.utilization, let resetsAt = window.resetsAt else { return nil }
        return UsageDisplayState(
            percentUsed: Int(percent.rounded()),
            severity: severity(forPercent: percent),
            windowKind: kind,
            resetsAt: resetsAt
        )
    }

    private static func severity(forPercent percent: Double) -> UsageDisplayState.Severity {
        switch percent {
        case ..<70: return .normal
        case 70..<90: return .warning
        default: return .critical
        }
    }
}
