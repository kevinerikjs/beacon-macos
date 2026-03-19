// BeaconApp.swift
// App entry point for Beacon (Beam's macOS host).
// Runs as a menu bar app (LSUIElement = YES) - no dock icon, no main window.

import SwiftUI
import ScreenCaptureKit
import Sparkle

// MARK: - App Delegate

final class BeaconAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Track window visibility so the Dock icon appears only when a window is open.
        // keyNotification fires when a window comes forward; willClose fires before dismissal.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowSetChanged),
                name: name,
                object: nil
            )
        }

        // Onboarding is triggered from AppState.init() where self is guaranteed available.
    }

    /// Called whenever a window gains focus or is about to close.
    /// Re-evaluates whether the Dock icon should be shown.
    @objc private func windowSetChanged() {
        // Defer so willClose has time to complete before we query window visibility.
        DispatchQueue.main.async { Self.syncActivationPolicy() }
    }

    /// Show the Dock icon iff at least one regular-level window is currently visible.
    /// Menu bar extra windows sit at a much higher window level and are excluded.
    static func syncActivationPolicy() {
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && $0.level == .normal
        }
        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }
}

// MARK: - App Entry Point

@main
struct BeaconApp: App {

    @NSApplicationDelegateAdaptor(BeaconAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    /// Sparkle updater controller — owns the update check lifecycle.
    /// Stored as a property so it lives for the duration of the app.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        // Menu bar icon + dropdown
        MenuBarExtra {
            StatusItemView(updater: updaterController.updater)
                .environment(appState)
        } label: {
            MenuBarIconLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)

        // Preferences window (opened via menu)
        Settings {
            SettingsView()
                .environment(appState)
                .frame(width: 420, height: 400)
        }
    }
}

// MARK: - Menu Bar Icon Label

/// The icon shown in the system menu bar.
/// - Idle: secondary monochrome icon
/// - Streaming: add violet status dot
/// - Window mode active: add orange status dot
/// - Both active: both dots shown
struct MenuBarIconLabel: View {
    @Environment(AppState.self) private var appState

    /// Brand streaming color #7163FF
    private let beamViolet = Color(red: 113 / 255, green: 99 / 255, blue: 255 / 255)

    var body: some View {
        HStack(spacing: 3) {
            Image("lighthouse")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(appState.isStreaming ? beamViolet : .secondary)

            VStack(spacing: 2) {
                if appState.isStreaming {
                    Circle()
                        .fill(beamViolet)
                        .frame(width: 5, height: 5)
                }
                if appState.isWindowMode {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 6, height: 10, alignment: .center)
            .opacity((appState.isStreaming || appState.isWindowMode) ? 1 : 0)
        }
    }
}
