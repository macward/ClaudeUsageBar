import AppKit
import SwiftUI

// MARK: - App

@main
internal struct ClaudeUsageBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate: AppDelegate

    internal var body: some Scene {
        MenuBarExtra {
            UsageDetailView()
                .environment(delegate.viewModel)
        } label: {
            UsageMenuLabelContainer()
                .environment(delegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Label Container

/// Exists purely so the menu bar label re-renders when the ViewModel's state changes:
/// `@Observable` tracking only happens inside a `View` body, not inside a `Scene` body, so
/// reading `state` directly in `ClaudeUsageBarApp.body` would render once and never update.
/// ``UsageMenuLabelView`` itself stays a pure control taking a plain `state` parameter.
internal struct UsageMenuLabelContainer: View {

    @Environment(UsageMenuViewModel.self) private var viewModel: UsageMenuViewModel

    internal var body: some View {
        UsageMenuLabelView(state: viewModel.state)
    }
}

// MARK: - Delegate

/// Composition root: the only place that builds the concrete service graph. Nothing here is a
/// singleton — the graph is created once and handed down through `.environment`.
///
/// The graph is built in `init`, not in `applicationDidFinishLaunching`: the delegate is created
/// while the `App` value itself is constructed at launch, so the usage cycle starts without
/// waiting for the popover — `MenuBarExtra` builds its content lazily, so anything hung off the
/// popover would only run once the user clicked the icon. Building here also keeps `viewModel`
/// non-optional, which matters because a value assigned later in the launch sequence does not
/// reliably propagate into an already-rendered `Scene` body.
///
/// It is an `NSApplicationDelegate` because that is what gives a `MenuBarExtra`-only app an owner
/// with app-lifetime scope: `@NSApplicationDelegateAdaptor` retains this instance for as long as
/// the app runs, so the object graph outlives every scene re-evaluation without anyone reaching
/// for a singleton.
///
/// Keep this initializer non-blocking. It runs on the main thread as part of `App` construction,
/// so anything synchronous added here (a file read, a Keychain call) would stall launch itself
/// rather than merely delaying the popover.
internal final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    internal let viewModel: UsageMenuViewModel

    // MARK: - Lifecycle

    internal override init() {
        let repository: UsageRepository = UsageRepository(
            credentialsService: ClaudeCodeCredentialsService(),
            apiService: UsageAPIService(),
            userDefaults: .standard
        )
        self.viewModel = UsageMenuViewModel(
            repository: repository,
            isPollingEnabled: true,
            userDefaults: .standard
        )
        super.init()
    }

    // MARK: - NSApplicationDelegate

    /// Opts the app out of being terminated on the system's own initiative.
    ///
    /// A `MenuBarExtra`-only app has no windows, so AppKit marks it automatically terminable
    /// (`_kLSApplicationWouldBeTerminatedByTALKey=1`) and RunningBoard rates it
    /// `maxTerminationResistance: NonInteractive` — free to kill. With the disk near full,
    /// `cachedelete` takes that offer to purge the sandbox container's caches, and the icon simply
    /// vanishes from the menu bar with no crash report, because it never crashed:
    ///
    ///     OS_REASON_RUNNINGBOARD | code:0xBADDD15C
    ///     CacheDeleteAppContainerCaches requesting termination assertion
    ///
    /// Both calls are needed and they cover different doors: automatic termination is the "no
    /// windows, nothing to lose" path, sudden termination the "kill without running teardown" one.
    /// Neither makes the app immune — under real memory pressure the system still wins, and a disk
    /// with no room left is a problem no app-side flag fixes — but they stop it from being the
    /// cheapest process on the machine to reap.
    internal func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("vive en la menu bar, sin ventanas que cerrar")
        ProcessInfo.processInfo.disableSuddenTermination()
    }
}
