// SettingsView.swift
// Preferences window for Beacon.

import SwiftUI
import Carbon.HIToolbox
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

            ControlsSettingsTab()
                .tabItem { Label("Controls", systemImage: "gamecontroller") }
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
    /// window jump every time you switch tabs. Pinning all four to the tallest keeps the window
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

// MARK: - Controls Tab

struct ControlsSettingsTab: View {
    @State private var store = PhoneControlsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Phone media buttons")
                    .font(.title3.weight(.semibold))
                Text("Choose what each button on your iPhone sends to Beacon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(PhoneControlsStore.buttonIDs, id: \.self) { id in
                    PhoneControlSettingsGroup(controlID: id, store: store)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
    }
}

private struct PhoneControlSettingsGroup: View {
    @Environment(AppState.self) private var appState
    @Bindable private var store: PhoneControlsStore

    let controlID: String
    @State private var showIconPicker = false
    @State private var showMacroRecorder = false

    init(controlID: String, store: PhoneControlsStore) {
        self.controlID = controlID
        _store = Bindable(wrappedValue: store)
    }

    private var controlTitle: String {
        switch controlID {
        case "seek_backward": return "Rewind"
        case "seek_forward":  return "Fast Forward"
        case "play_pause":    return "Play/Pause"
        default:               return controlID
        }
    }

    var body: some View {
        let config = store.config(for: controlID)

        settingsGroup(header: controlTitle) {
            settingsRow("Icon") {
                Button {
                    showIconPicker = true
                } label: {
                    Image(systemName: config.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Choose icon")
            }

            Divider().padding(.leading, 12)

            settingsRow("Label") {
                TextField("Label", text: labelBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }

            Divider().padding(.leading, 12)

            settingsRow("Action") {
                Picker("Action", selection: actionPresetBinding) {
                    ForEach(PhoneControlAction.Preset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170)
            }

            switch config.action {
            case .shortcut(let keyCode, let modifiers):
                Divider().padding(.leading, 12)
                settingsRow("Shortcut") {
                    PhoneShortcutRecorderView(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        onChange: setShortcut
                    )
                }
            case .macro(let steps):
                Divider().padding(.leading, 12)
                settingsRow("Macro") {
                    macroControls(steps: steps)
                }
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $showIconPicker) {
            PhoneSymbolPickerView(selectedSymbol: config.symbol) { symbol in
                updateConfig { $0.symbol = symbol }
            }
        }
        .sheet(isPresented: $showMacroRecorder) {
            MacroRecorderSheet(initialSteps: macroSteps, onSave: setMacro)
                .environment(appState)
        }
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { store.config(for: controlID).label },
            set: { value in updateConfig { $0.label = value } }
        )
    }

    private var actionPresetBinding: Binding<PhoneControlAction.Preset> {
        Binding(
            get: { store.config(for: controlID).action.preset },
            set: { preset in
                updateConfig { config in
                    config.action = config.action.replacingPreset(preset)
                }
            }
        )
    }

    private var macroSteps: [MacroStep] {
        if case .macro(let steps) = store.config(for: controlID).action {
            return steps
        }
        return []
    }

    @ViewBuilder
    private func macroControls(steps: [MacroStep]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(steps.count) \(steps.count == 1 ? "step" : "steps")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    setMacro([])
                }
                .buttonStyle(.borderless)
                .disabled(steps.isEmpty)
                Button("Record macro…") {
                    showMacroRecorder = true
                }
                .buttonStyle(.bordered)
            }

            if !appState.hasAccessibilityPermission || !AXIsProcessTrusted() {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Accessibility access is required to record macros.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Grant Access…") {
                        requestPhoneControlAccessibilityPermission()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .frame(minWidth: 255, alignment: .trailing)
    }

    private func setShortcut(keyCode: UInt32, modifiers: UInt32) {
        updateConfig { $0.action = .shortcut(keyCode: keyCode, modifiers: modifiers) }
    }

    private func setMacro(_ steps: [MacroStep]) {
        updateConfig { $0.action = .macro(steps) }
    }

    private func updateConfig(_ update: (inout PhoneControlConfig) -> Void) {
        var config = store.config(for: controlID)
        update(&config)
        store.setConfig(config, for: controlID)
    }
}

private struct PhoneSymbolPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let selectedSymbol: String
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    private static let symbols = [
        "gobackward", "goforward", "gobackward.10", "goforward.10", "gobackward.15",
        "goforward.15", "gobackward.30", "goforward.30", "backward.fill", "forward.fill",
        "backward.end.fill", "forward.end.fill", "playpause.fill", "play.fill", "pause.fill",
        "stop.fill", "arrow.left", "arrow.right", "arrow.up", "arrow.down", "chevron.left",
        "chevron.right", "arrow.uturn.left", "arrow.uturn.right", "arrow.clockwise",
        "arrow.counterclockwise", "speaker.wave.2.fill", "speaker.slash.fill",
        "plus.magnifyingglass", "minus.magnifyingglass", "rectangle.on.rectangle",
        "square.grid.2x2", "list.bullet", "bookmark.fill", "star.fill", "heart.fill",
        "hand.thumbsup.fill", "text.bubble.fill", "keyboard", "command", "option", "shift",
        "escape", "return", "space", "tab", "magnifyingglass", "house.fill", "folder.fill",
        "doc.fill", "camera.fill", "video.fill", "mic.fill", "display", "macwindow",
        "sidebar.left", "sidebar.right", "arrow.left.arrow.right", "arrow.up.arrow.down",
        "repeat", "shuffle", "bolt.fill", "timer", "ellipsis.circle.fill", "cursorarrow"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an icon")
                .font(.headline)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            onSelect(symbol)
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(symbol == selectedSymbol ? Color.accentColor.opacity(0.2) : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(symbol == selectedSymbol ? Color.accentColor : .clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 410, height: 430)
    }
}

private struct PhoneShortcutRecorderView: View {
    let keyCode: UInt32
    let modifiers: UInt32
    let onChange: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press a key…" : phoneControlDisplayString(keyCode: keyCode, modifiers: modifiers))
                .font(.callout.monospaced())
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .orange : nil)
        .help("Record a key or shortcut")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            onChange(UInt32(event.keyCode), modifiers)
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

private struct MacroRecorderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onSave: ([MacroStep]) -> Void

    @State private var steps: [MacroStep]
    @State private var isRecording = false
    @State private var globalMonitor: Any?
    @State private var localMonitor: Any?
    @State private var idleTimer: Timer?
    @State private var lastEventUptime: TimeInterval?

    init(initialSteps: [MacroStep], onSave: @escaping ([MacroStep]) -> Void) {
        self.onSave = onSave
        _steps = State(initialValue: initialSteps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record macro")
                .font(.headline)
            Text("Press the keys you want to replay. Recording stops after 10 seconds without a key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.hasAccessibilityPermission || !AXIsProcessTrusted() {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Accessibility access is required to record macros.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Grant Access…") {
                        requestPhoneControlAccessibilityPermission()
                    }
                    .buttonStyle(.link)
                }
            }

            HStack {
                Label("\(steps.count) \(steps.count == 1 ? "step" : "steps")", systemImage: "list.number")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    steps.removeAll()
                }
                .buttonStyle(.borderless)
                .disabled(steps.isEmpty || isRecording)
                Button(isRecording ? "Stop" : "Record macro…") {
                    isRecording ? stopRecording() : startRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .orange : nil)
                .disabled(!isRecording && !AXIsProcessTrusted())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if steps.isEmpty {
                        Text("No keys recorded")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(phoneControlDisplayString(keyCode: step.keyCode, modifiers: step.modifiers))
                                    .font(.callout.monospaced())
                                if index > 0 {
                                    Text("after \(step.delayMs) ms")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("starts immediately")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Done") {
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 390)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard AXIsProcessTrusted() else {
            requestPhoneControlAccessibilityPermission()
            return
        }

        isRecording = true
        lastEventUptime = nil
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            record(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
        armIdleTimer()
    }

    private func record(_ event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let delayMs: UInt32
        if let lastEventUptime {
            let elapsed = max(0, min((now - lastEventUptime) * 1_000, Double(UInt32.max)))
            delayMs = UInt32(elapsed.rounded())
        } else {
            delayMs = 0
        }

        steps.append(MacroStep(
            keyCode: UInt32(event.keyCode),
            modifiers: HotkeyManager.carbonModifiers(from: event.modifierFlags),
            delayMs: delayMs
        ))
        lastEventUptime = now
        armIdleTimer()
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            stopRecording()
        }
    }

    private func stopRecording() {
        isRecording = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        lastEventUptime = nil
    }

    private func finish() {
        stopRecording()
        onSave(steps)
        dismiss()
    }
}

private func phoneControlDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
    var parts = ""
    if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
    return parts + HotkeyManager.keyName(for: keyCode)
}

private func requestPhoneControlAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
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
