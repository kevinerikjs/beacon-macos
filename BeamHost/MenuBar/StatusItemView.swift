// StatusItemView.swift
// The dropdown menu content shown when the user clicks the menu bar icon.

import SwiftUI
import ScreenCaptureKit

struct StatusItemView: View {
    @Environment(AppState.self) private var appState
    @State private var isPairingWindowVisible = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Status header
        statusSection

        Divider()

        // Display picker
        displaySection

        Divider()

        // Paired devices
        pairedDevicesSection

        Divider()

        Button("Preferences…") {
            openSettings()
            // Bring app to front so settings window appears
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit Beam") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        if appState.isStreaming, let device = appState.connectedDeviceName {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Streaming to \(device)")
                    .font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Button("Stop Streaming") {
                appState.stopStreaming()
            }
        } else if !appState.hasCapturePermission {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Screen Recording permission needed")
                    .font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Button("Open Privacy Settings…") {
                openPrivacySettings()
            }
        } else if appState.pairedDevices.isEmpty {
            Text("No devices paired")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                Text("Ready — waiting for iPhone")
                    .font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Display Section

    @ViewBuilder
    private var displaySection: some View {
        if appState.availableDisplays.isEmpty {
            Text("No displays found")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        } else {
            Text("Streaming Display")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)

            @Bindable var state = appState
            ForEach(Array(appState.availableDisplays.enumerated()), id: \.offset) { index, display in
                Button {
                    appState.selectedDisplayIndex = index
                } label: {
                    HStack {
                        Text(displayName(for: display, index: index))
                        Spacer()
                        if appState.selectedDisplayIndex == index {
                            Image(systemName: "checkmark")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Paired Devices Section

    @ViewBuilder
    private var pairedDevicesSection: some View {
        Text("Paired Devices")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 2)

        if appState.pairedDevices.isEmpty {
            Button("Pair New Device…") {
                openPairingWindow()
            }
        } else {
            ForEach(appState.pairedDevices) { device in
                Menu(device.name) {
                    Button("Unpair \(device.name)") {
                        appState.unpairDevice(id: device.id)
                    }
                }
            }
            Button("Pair Another Device…") {
                openPairingWindow()
            }
        }
    }

    // MARK: - Helpers

    private func displayName(for display: SCDisplay, index: Int) -> String {
        if index == 0 { return "Display 1 (Main)" }
        return "Display \(index + 1)"
    }

    private func openPairingWindow() {
        // Open the pairing window - hosted as a separate NSWindow
        PairingWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
