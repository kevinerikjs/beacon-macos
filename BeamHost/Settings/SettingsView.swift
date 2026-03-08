// SettingsView.swift
// Preferences window for Beacon.

import SwiftUI
import ScreenCaptureKit
import ServiceManagement
import ApplicationServices

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .environment(appState)

            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "display") }
                .environment(appState)

            PairedDevicesTab()
                .tabItem { Label("Devices", systemImage: "iphone") }
                .environment(appState)
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 6) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                Text("Beacon")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)

            settingsGroup(header: "Behavior") {
                Toggle("Launch Beacon at login", isOn: $state.launchAtLogin)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsGroup(header: "Permissions") {
                settingsRow("Screen Recording") {
                    if appState.hasCapturePermission {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Grant Access…") {
                            openPrivacySettings(privacy: "Privacy_ScreenCapture")
                        }
                        .buttonStyle(.link)
                    }
                }
                Divider().padding(.leading, 12)
                settingsRow("Media Key Control") {
                    if appState.hasAccessibilityPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Grant Accessibility…") {
                            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(opts)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func openPrivacySettings(privacy: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacy)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Display Tab

struct DisplaySettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(header: "Streaming Display") {
                if appState.availableDisplays.isEmpty {
                    settingsRow("Display") {
                        Text("No displays found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    settingsRow("Display") {
                        Picker("", selection: $state.selectedDisplayIndex) {
                            ForEach(Array(appState.availableDisplays.enumerated()), id: \.offset) { index, display in
                                Text(displayName(for: display, index: index))
                                    .tag(index)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
            }

            settingsGroup(header: "Quality") {
                settingsRow("Default Preset") {
                    Picker("", selection: Binding(
                        get: { appState.qualityManager.preferredPreset },
                        set: { appState.qualityManager.preferredPreset = $0 }
                    )) {
                        ForEach(StreamQualityPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                }
                if appState.qualityManager.preferredPreset == .auto {
                    Text("Auto adjusts resolution and frame rate based on connection quality reported by the iOS app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    let p = appState.qualityManager.preferredPreset
                    Text("\(p.width)×\(p.height) · \(Int(p.fps)) fps · \(String(format: "%.1f", p.bitrateMbps)) Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func displayName(for display: SCDisplay, index: Int) -> String {
        "Display \(index + 1)\(index == 0 ? " (Main)" : "")"
    }
}

// MARK: - Paired Devices Tab

struct PairedDevicesTab: View {
    @Environment(AppState.self) private var appState
    @State private var selectedDeviceID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.pairedDevices.isEmpty {
                ContentUnavailableView {
                    Label("No Paired Devices", systemImage: "iphone.slash")
                } description: {
                    Text("Pair an iPhone using the menu bar icon.")
                }
            } else {
                List(selection: $selectedDeviceID) {
                    ForEach(appState.pairedDevices) { device in
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.callout)
                                Text("Last seen: \(device.lastSeen.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(device.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))

                HStack {
                    Spacer()
                    Button("Unpair Selected") {
                        if let id = selectedDeviceID {
                            appState.unpairDevice(id: id)
                            selectedDeviceID = nil
                        }
                    }
                    .disabled(selectedDeviceID == nil)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Layout Helpers

@ViewBuilder
private func settingsGroup<Content: View>(
    header: String? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if let header {
            Text(header)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        VStack(spacing: 0) {
            content()
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

@ViewBuilder
private func settingsRow<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    HStack {
        Text(label)
        Spacer()
        content()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
}
