//
//  ClaudeUsageBarApp.swift
//  ClaudeUsageBar
//
//  Created by Max Ward on 30/07/2026.
//

import AppKit
import SwiftUI

// MARK: - App

@main
internal struct ClaudeUsageBarApp: App {

    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var delegate: SpikeAppDelegate

    internal var body: some Scene {
        MenuBarExtra("ClaudeUsageBar", systemImage: "gauge.with.needle") {
            SpikeView()
                .environment(delegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Delegate

/// `applicationDidFinishLaunching` is the only launch hook that fires regardless of whether the
/// menu bar popover is ever opened — SwiftUI builds `MenuBarExtra` content lazily.
internal final class SpikeAppDelegate: NSObject, NSApplicationDelegate {

    internal let viewModel: SpikeViewModel = SpikeViewModel()

    internal func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("spike: launched\n".utf8))
        Task { @MainActor in
            await viewModel.runAll()
            if ProcessInfo.processInfo.environment["SPIKE_EXIT_WHEN_DONE"] != nil {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
