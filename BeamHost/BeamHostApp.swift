// BeamHostApp.swift
// App entry point for Beam macOS host.
// Runs as a menu bar app (LSUIElement = YES) - no dock icon, no main window.

import SwiftUI
import ScreenCaptureKit

@main
struct BeamHostApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        // Menu bar icon + dropdown
        MenuBarExtra {
            StatusItemView()
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
                .frame(width: 420, height: 320)
        }
    }
}

// MARK: - Menu Bar Icon Label

/// The icon shown in the system menu bar. Animates when streaming.
struct MenuBarIconLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isStreaming {
                Image(systemName: "dot.radiowaves.right")
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "dot.radiowaves.right")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
