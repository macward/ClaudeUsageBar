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
    /// No snapshot has ever landed *and* the repository is refusing to fetch. Once any snapshot
    /// exists this case is unreachable: a throttle then travels on
    /// ``UsageMenuViewModel/throttledUntil`` instead, leaving the data on screen.
    case throttled(until: Date)
    case sessionExpired
    case error(UsageMenuError)

    /// Whether this case carries usage numbers the user can currently read. Drives the decision to
    /// preserve rather than replace the screen when a refresh is refused.
    internal var showsUsageData: Bool {
        switch self {
        case .fresh, .stale:
            return true
        case .onboarding, .loading, .throttled, .sessionExpired, .error:
            return false
        }
    }
}

/// Everything the popover's detail view needs, already resolved — the label only ever needs
/// `dominant`, but the detail view shows both windows plus any active per-limit entries
/// (per-model limits, etc.), all pre-derived here so no threshold/severity logic has to live
/// in the views.
internal struct UsageDetailData: Equatable, Sendable {
    /// What the menu bar label shows: the 5-hour session window whenever the snapshot carries it,
    /// falling back to `sevenDay` and then to the highest active limit. See
    /// ``UsageMenuViewModel/deriveDisplayState(from:)`` for the full rule.
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

    /// When the repository will next allow a fetch, set only when it has actually refused one.
    /// `nil` whenever the last result came back from the network (or cache).
    ///
    /// Deliberately a separate axis from ``state``: a throttle is a fact about the *next fetch*,
    /// not about the data already on screen. Folding it into `state` is what used to blank the
    /// popover — and the menu bar percentage with it — the moment a refresh landed inside the
    /// repository's 180s window, replacing a good snapshot with a bare countdown.
    ///
    /// No view renders it today (the manual refresh action it used to gate is gone). It stays
    /// because it is the only externally visible evidence that a call actually reached the
    /// repository and was refused, which is what distinguishes a repository throttle from the
    /// ViewModel's own popover TTL declining to ask at all.
    internal private(set) var throttledUntil: Date?

    private let repository: UsageRepository
    private let userDefaults: UserDefaults
    private let isPollingEnabled: Bool

    private var pollingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// When the snapshot currently reflected in `state` was actually fetched — reconstructed
    /// from `.fresh`'s implicit "now" or `.stale`'s explicit `age`. `nil` until the first
    /// successful (fresh or stale) result ever lands.
    ///
    /// Exposed because the popover shows it: with no manual refresh action left, the age of the
    /// data is the only thing that answers "is this number current?".
    internal private(set) var currentSnapshotFetchedAt: Date?

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
        // A throttle is the one result that must not clobber what is already displayed, so it is
        // handled apart from the cases that genuinely replace the screen.
        guard case .throttled(let until) = result else {
            throttledUntil = nil
            applyResolved(result)
            return
        }

        throttledUntil = until
        // Taking over the screen is right only when there is nothing to preserve — a first launch
        // throttled before any snapshot ever landed. Otherwise the numbers stay put and the wait
        // shows up next to the (now disabled) refresh action.
        if !state.showsUsageData {
            state = .throttled(until: until)
        }
    }

    private func applyResolved(_ result: UsageRepositoryResult) {
        switch result {
        case .fresh(let snapshot):
            currentSnapshotFetchedAt = Date()
            state = Self.deriveDetailData(from: snapshot).map(UsageMenuState.fresh) ?? .error(.noUsableData)
        case .stale(let snapshot, let age):
            currentSnapshotFetchedAt = Date().addingTimeInterval(-age)
            state = Self.deriveDetailData(from: snapshot).map { .stale($0, age: age) } ?? .error(.noUsableData)
        case .throttled:
            // Routed away by `apply(_:)`; kept exhaustive rather than defaulted so a new result
            // case cannot slip through unhandled.
            break
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
        let namedWindows: [UsageDisplayState] = [fiveHour, sevenDay].compactMap { $0 }
        let extraLimits: [UsageDisplayState] = (snapshot.limits ?? []).compactMap { limit in
            guard let display = limitDisplayState(limit) else { return nil }
            // A per-model cap is never a restatement of a named window, whatever its reset lands
            // on, so it skips the duplicate check entirely rather than relying on its `kind` not
            // being a known alias. See ``isDuplicate(_:of:)`` for why that distinction matters.
            guard limit.scope?.model?.displayName == nil else { return display }
            return isDuplicate(display, of: namedWindows) ? nil : display
        }

        return UsageDetailData(dominant: dominant, fiveHour: fiveHour, sevenDay: sevenDay, limits: extraLimits)
    }

    /// Every entry in `limits[]` that carries a usable percentage — deliberately *not* filtered by
    /// `is_active`.
    ///
    /// That filter used to be here and was wrong: the endpoint reports the live session window as
    /// `is_active: false` while it sits at 22% with hours left on the clock, and marks only the
    /// single highest limit as `true`. So the flag doesn't mean "this cap applies to you" — it
    /// looks like "this is the cap currently closest to binding". Filtering on it silently dropped
    /// real limits, most visibly the per-model weekly cap (`weekly_scoped`, e.g. Fable), which is
    /// the whole point of showing this list.
    ///
    /// Restatements of the two named windows are removed by ``isDuplicate(_:of:)`` at the call
    /// site instead, which keys off scope and reset time — facts about the window itself rather
    /// than a flag whose meaning is inferred.
    private static func limitDisplayStates(from snapshot: UsageSnapshot) -> [UsageDisplayState] {
        (snapshot.limits ?? []).compactMap(limitDisplayState)
    }

    /// The server reports the weekly window twice: once as `seven_day`, and again as a
    /// `weekly_all` entry in `limits[]` with the same percentage and the same reset — which
    /// painted two identical rows in the popover.
    ///
    /// A limit counts as a duplicate only when it's a restatement of the *same scope* as an
    /// already-shown named window (`session`/`weekly`, per ``scopeAlias(for:)``) **and** resets at
    /// the same instant. Both halves are required: a per-model limit can legitimately share the
    /// session's reset time (an Opus cap inside the same 5-hour window) and must still get its own
    /// row, and an unrecognized key is never treated as a duplicate — when in doubt, show it.
    private static func isDuplicate(_ limit: UsageDisplayState, of namedWindows: [UsageDisplayState]) -> Bool {
        guard let alias = scopeAlias(for: limit.windowKind) else { return false }
        return namedWindows.contains { window in
            window.windowKind == alias
                && abs(window.resetsAt.timeIntervalSince(limit.resetsAt)) < duplicateResetTolerance
        }
    }

    /// The two sources for the same window are generated server-side from the same clock, so their
    /// resets match to the microsecond in practice. The tolerance only absorbs a future rounding
    /// difference between the fields — it is deliberately far below the shortest window (5 hours),
    /// so two genuinely different windows can never fall inside it.
    private static let duplicateResetTolerance: TimeInterval = 60

    /// Maps a `limits[]` key onto the named window it restates, or nil when the key describes
    /// something narrower (a per-model cap) or simply isn't recognized.
    ///
    /// Only keys actually observed from the endpoint are listed. Guessing extra aliases would cut
    /// the wrong way: an alias that turns out to name something narrower than the named window
    /// makes a legitimate row disappear silently, whereas an unrecognized key merely shows an
    /// extra row. Under-matching is the safe failure here, so new aliases get added when they're
    /// seen, not in anticipation.
    ///
    /// **`weekly_scoped` must never be added here.** It reads like a weekly alias and isn't — it's
    /// the per-model cap, and the server resets it at `23:59:59` against the weekly window's
    /// `00:00:00` the next day: under a second apart, far inside ``duplicateResetTolerance``. As an
    /// alias it would match the weekly window on both halves and the per-model row would vanish
    /// without a trace. The call site guards this independently by skipping the duplicate check for
    /// anything carrying a model scope, so this is defence in depth rather than the only barrier.
    private static func scopeAlias(for kind: String) -> String? {
        switch kind.lowercased() {
        case "session", "five_hour":
            return "five_hour"
        case "weekly", "weekly_all", "seven_day":
            return "seven_day"
        default:
            return nil
        }
    }

    /// Row title for a `limits[]` entry, model scope included when the entry carries one.
    ///
    /// A scoped entry's `kind` is just `weekly_scoped` — the model it caps lives only in
    /// `scope.model.display_name`, so without this the row would read "Weekly scoped" and never
    /// name the model. Composed against `group` rather than `kind` because `group` is the coarse,
    /// stable axis (`session`/`weekly`) while `kind` is where new variants keep appearing.
    ///
    /// With a model but no recognizable group, the model name stands alone: a row reading "Fable"
    /// is still useful, "Weekly scoped" is not.
    private static func title(for limit: UsageSnapshot.Limit, kind: String) -> String {
        guard let model = limit.scope?.model?.displayName, !model.isEmpty else {
            return title(forKind: kind)
        }
        guard let base = groupTitle(for: limit.group ?? kind) else { return model }
        return "\(base) · \(model)"
    }

    /// The coarse window a limit belongs to, or nil when the group isn't one this build knows.
    private static func groupTitle(for group: String) -> String? {
        switch group.lowercased() {
        case "session", "five_hour":
            return "Últimas 5 horas"
        case "weekly", "seven_day":
            return "Semanal"
        default:
            return nil
        }
    }

    /// Turns an endpoint key into a row title. Known keys get real Spanish labels; anything else
    /// is humanized rather than dropped or shown raw — the endpoint is undocumented and its keys
    /// rotate (`tangelo`, `seven_day_omelette`), so an unrecognized key has to degrade into
    /// something readable instead of leaking `weekly_all` onto the screen or rendering blank.
    private static func title(forKind kind: String) -> String {
        switch kind.lowercased() {
        case "session", "five_hour":
            return "Últimas 5 horas"
        case "weekly", "weekly_all", "seven_day":
            return "Semanal"
        case "opus":
            return "Opus"
        case "weekly_opus":
            return "Semanal · Opus"
        default:
            return humanized(kind)
        }
    }

    /// `weekly_sonnet` → "Weekly sonnet". Deliberately mechanical: it can't invent a good name for
    /// a key nobody has seen, only guarantee the row is legible and never empty.
    private static func humanized(_ kind: String) -> String {
        let words: String = kind
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = words.first else { return "Otro límite" }
        return first.uppercased() + words.dropFirst()
    }

    /// Picks the window the menu bar label shows. The rule is a fixed preference order, not a
    /// max: the 5-hour session is *always* the dominant window when it's present, because that's
    /// the number that matters at a glance and the one Claude Desktop leads with. Picking the
    /// highest instead would show 31% (weekly) while the session sits at 2% — technically the
    /// window closest to running out, but not the one the user is asking about.
    ///
    /// Fallback chain, in order, so the label is never empty while the snapshot carries anything
    /// usable at all:
    /// 1. `five_hour`
    /// 2. `seven_day` — when the response omits the session window
    /// 3. the highest active entry in `limits[]` — last resort, unchanged from before
    ///
    /// With none of the three usable, this returns nil and the caller surfaces
    /// `.error(.noUsableData)`.
    ///
    /// Severity is derived from the chosen percentage directly (<70 normal, 70–89 warning,
    /// ≥90 critical), not trusted from the server's own `severity` string, so the menu bar's
    /// thresholds stay consistent regardless of what the endpoint reports.
    private static func deriveDisplayState(from snapshot: UsageSnapshot) -> UsageDisplayState? {
        if let fiveHour = windowDisplayState(kind: "five_hour", window: snapshot.fiveHour) {
            return fiveHour
        }
        if let sevenDay = windowDisplayState(kind: "seven_day", window: snapshot.sevenDay) {
            return sevenDay
        }

        return limitDisplayStates(from: snapshot).max { $0.percentUsed < $1.percentUsed }
    }

    private static func limitDisplayState(_ limit: UsageSnapshot.Limit) -> UsageDisplayState? {
        guard let percent = limit.percent, let resetsAt = limit.resetsAt else { return nil }
        let kind: String = limit.kind ?? "limit"
        return UsageDisplayState(
            percentUsed: Int(percent.rounded()),
            severity: severity(forPercent: percent),
            windowKind: kind,
            title: title(for: limit, kind: kind),
            resetsAt: resetsAt
        )
    }

    private static func windowDisplayState(kind: String, window: UsageSnapshot.Window?) -> UsageDisplayState? {
        guard let window, let percent = window.utilization, let resetsAt = window.resetsAt else { return nil }
        return UsageDisplayState(
            percentUsed: Int(percent.rounded()),
            severity: severity(forPercent: percent),
            windowKind: kind,
            title: title(forKind: kind),
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
