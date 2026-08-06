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
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    /// One fixed size for every tab, sized to the tallest one.
    ///
    /// A TabView sizes itself to whichever tab is showing, so letting it size naturally makes the
    /// window jump every time you switch tabs. Pinning all three to the tallest keeps the window
    /// still, at the cost of some empty space under Display and Devices.
    ///
    /// General is the tallest and sets this number: app header, Behavior, Global Hotkey,
    /// Permissions, Support, and Open Source. Grow this if you add a row to General, or the
    /// bottom of that tab will clip. The scene sets `.windowResizability(.contentSize)`, so this
    /// is the window size, not a minimum.
    static let windowSize = CGSize(width: 460, height: 730)
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showFeedback = false

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

            settingsGroup(header: "Global Hotkey") {
                Toggle("Toggle window mode from anywhere", isOn: Binding(
                    get: { HotkeyManager.shared.isEnabled },
                    set: { HotkeyManager.shared.isEnabled = $0 }
                ))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.leading, 12)
                settingsRow("Shortcut") {
                    HotkeyRecorderView()
                }
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

            settingsGroup(header: "Support") {
                Button {
                    showFeedback = true
                } label: {
                    HStack {
                        Text("Send Feedback…")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Divider()

                // Beam for iPhone is the other half of this product and the app never linked to
                // it. Someone pairing a second phone, or reinstalling, had no way to find it
                // from here.
                HStack(spacing: 12) {
                    Link("Beam for iPhone", destination: URL(string: "https://beamscreen.app")!)
                    Link("Setup Guide", destination: URL(string: "https://beamscreen.app/guide/mirror-mac-to-iphone")!)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // AGPL section 5 requires an interactive program to display Appropriate Legal
            // Notices. This is that, and it doubles as the trust signal for an app that holds
            // Screen Recording permission: the person wondering what Beacon does with their
            // screen is already here in Settings.
            settingsGroup(header: "Open Source") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Beacon is free software, licensed under the GNU Affero General Public License v3.0.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can read every line of it, including exactly what it does with your screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Link("View Source", destination: URL(string: "https://github.com/kevinerikjs/beacon-macos")!)
                        Link("License", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
                        Link("Commercial Use", destination: URL(string: "https://github.com/kevinerikjs/beacon-macos/blob/main/COMMERCIAL-LICENSE.md")!)
                    }
                    .font(.callout)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showFeedback) {
            MacFeedbackView()
        }
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

            remoteAccessSection
        }
        .padding(.vertical, 8)
    }

    // MARK: - Remote access (BEAM-19)

    /// Shows this Mac's Tailscale address so it can be entered by hand on an iPhone that
    /// paired before Tailscale was set up. Paired devices normally receive this automatically,
    /// so this is a fallback and a diagnostic — hidden entirely when there's no tailnet, to
    /// avoid advertising a feature the user hasn't got.
    @ViewBuilder
    private var remoteAccessSection: some View {
        if let address = tailscaleAddress {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Access")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    Text(address)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy address")
                }
                Text("Paired iPhones get this automatically and use it when they're away from "
                     + "your network. Both devices must be signed in to the same Tailscale account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Read once per view construction rather than polled — the address is stable while
    /// Tailscale is connected, and the settings window is short-lived.
    private var tailscaleAddress: String? { TailscaleAddress.current() }
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

// MARK: - Hotkey Recorder (BEAM-2)

/// Click → "Press shortcut…" → next keydown (with at least one of ⌘⌥⌃) becomes the binding.
/// Esc cancels. Uses a local key monitor only while recording.
struct HotkeyRecorderView: View {
    @State private var isRecording = false
    @State private var displayString = HotkeyManager.shared.displayString
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press shortcut…" : displayString)
                .font(.callout.monospaced())
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .orange : nil)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            // Require a real chord — a bare key would shadow normal typing system-wide.
            guard !event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
            let mods = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            HotkeyManager.shared.setBinding(keyCode: UInt32(event.keyCode), modifiers: mods)
            displayString = HotkeyManager.shared.displayString
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
