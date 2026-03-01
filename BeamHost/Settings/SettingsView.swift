// SettingsView.swift
// Preferences window for Beacon.

import SwiftUI
import ScreenCaptureKit
import ServiceManagement

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
        .frame(width: 420, height: 280)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Behavior") {
                Toggle("Launch Beacon at login", isOn: $state.launchAtLogin)
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Screen Recording")
                    Spacer()
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

                HStack {
                    Text("Media Key Control")
                    Spacer()
                    if appState.hasAccessibilityPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Grant Accessibility…") {
                            MediaKeyDispatcher.requestAccessibilityPermission()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
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

        Form {
            Section("Streaming Display") {
                if appState.availableDisplays.isEmpty {
                    Text("No displays found. Grant Screen Recording permission first.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Display", selection: $state.selectedDisplayIndex) {
                        ForEach(Array(appState.availableDisplays.enumerated()), id: \.offset) { index, display in
                            Text(displayName(for: display, index: index))
                                .tag(index)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            Section("Quality") {
                Picker("Default Preset", selection: Binding(
                    get: { appState.qualityManager.preferredPreset },
                    set: { appState.qualityManager.preferredPreset = $0 }
                )) {
                    ForEach(StreamQualityPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if appState.qualityManager.preferredPreset == .auto {
                    Text("Auto adjusts resolution and frame rate based on connection quality reported by the iOS app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let p = appState.qualityManager.preferredPreset
                    Text("\(p.width)×\(p.height) · \(Int(p.fps)) fps · \(String(format: "%.1f", p.bitrateMbps)) Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
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
