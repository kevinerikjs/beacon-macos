// SettingsView.swift
// Preferences window for Beacon.

import SwiftUI
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import ApplicationServices
import Observation

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .environment(appState)
                .tag("general")

            ControlsSettingsTab()
                .tabItem { Label("Controls", systemImage: "gamecontroller") }
                .environment(appState)
                .tag("controls")

            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "display") }
                .environment(appState)
                .tag("display")

            PairedDevicesTab()
                .tabItem { Label("Devices", systemImage: "iphone") }
                .environment(appState)
                .tag("devices")
        }
        .padding(20)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.bool(forKey: "beacon.debug.openSettings")
                || UserDefaults.standard.bool(forKey: "beacon.debug.openMacroEditor") {
                selectedTab = "controls"
            }
        }
        #endif
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
    @State private var showingRenameLayout = false
    @State private var showingDeleteLayout = false
    @State private var editingMacro: Macro?
    @State private var macroAssignment: (layoutID: UUID, buttonID: UUID)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Phone controls")
                    .font(.title3.weight(.semibold))
                Text("Build up to seven buttons for your iPhone, then choose the active layout.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                layoutControls

                let layout = store.activeLayout
                settingsGroup(header: "Buttons") {
                    ForEach(Array(layout.buttons.enumerated()), id: \.element.id) { index, button in
                        PhoneControlSettingsRow(
                            layout: layout,
                            button: button,
                            index: index,
                            store: store,
                            onEditMacro: presentMacroEditor
                        )
                        if button.id != layout.buttons.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }

                Button {
                    store.addButton(to: layout.id)
                } label: {
                    Label("Add button", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(layout.isBuiltIn || layout.buttons.count >= 7)

                macroLibrary

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            // SettingsView pads the whole tab by 20; the scroll view pulls itself back out to the
            // window edge so the scroll bar sits where every other macOS window puts it, and the
            // content re-applies the 20 inside.
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
        .scrollIndicators(.automatic)
        .sheet(isPresented: $showingRenameLayout) {
            LayoutNameSheet(title: "Rename Layout", initialName: store.activeLayout.name) { name in
                store.renameLayout(id: store.activeLayout.id, to: name)
            }
        }
        .sheet(item: $editingMacro) { macro in
            MacroEditorSheet(macro: macro) { saved in
                store.saveMacro(saved)
                if let assignment = macroAssignment {
                    store.updateButton(layoutID: assignment.layoutID, buttonID: assignment.buttonID) {
                        $0.action = .macro(id: saved.id)
                    }
                }
                macroAssignment = nil
            }
        }
        .alert("Delete \(store.activeLayout.name)?", isPresented: $showingDeleteLayout) {
            Button("Delete", role: .destructive) {
                store.deleteLayout(id: store.activeLayout.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This layout and its button settings will be removed.")
        }
        #if DEBUG
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "beacon.debug.openMacroEditor") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                editingMacro = Macro(
                    id: UUID(), name: "Example Macro",
                    steps: [
                        .keyDown(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), delayMs: 0),
                        .keyUp(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), delayMs: 120),
                        .keyDown(keyCode: UInt32(kVK_Return), modifiers: 0, delayMs: 320),
                        .keyUp(keyCode: UInt32(kVK_Return), modifiers: 0, delayMs: 70)
                    ]
                )
            }
        }
        #endif
    }

    private var layoutControls: some View {
        settingsGroup(header: "Active layout") {
            settingsRow("Layout") {
                Picker("Layout", selection: Binding(
                    get: { store.activeLayoutID },
                    set: { store.setActiveLayout($0) }
                )) {
                    ForEach(store.layouts) { layout in
                        Text(layout.name).tag(layout.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 185)
            }
            Divider().padding(.leading, 12)
            // Four equal-width buttons filling the row, like a segmented toolbar.
            HStack(spacing: 8) {
                Button { store.createLayout() } label: { Text("New").frame(maxWidth: .infinity) }
                Button { store.duplicateLayout(store.activeLayout) } label: { Text("Duplicate").frame(maxWidth: .infinity) }
                Button { showingRenameLayout = true } label: { Text("Rename").frame(maxWidth: .infinity) }
                    .disabled(store.activeLayout.isBuiltIn)
                Button(role: .destructive) { showingDeleteLayout = true } label: { Text("Delete").frame(maxWidth: .infinity) }
                    .disabled(store.activeLayout.isBuiltIn)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var macroLibrary: some View {
        settingsGroup(header: "Macro library") {
            if store.macros.isEmpty {
                Text("Create a macro to reuse it across buttons and layouts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(store.macros) { macro in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(macro.name)
                            Text("\(macro.steps.count) \(macro.steps.count == 1 ? "step" : "steps")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { presentMacroEditor(macro, nil) }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) { store.deleteMacro(id: macro.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete macro")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if macro.id != store.macros.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            Divider().padding(.leading, 12)
            Button {
                presentMacroEditor(Macro(id: UUID(), name: "New Macro", steps: []), nil)
            } label: {
                Label("New macro…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }

    private func presentMacroEditor(_ macro: Macro, _ assignment: (layoutID: UUID, buttonID: UUID)?) {
        macroAssignment = assignment
        editingMacro = macro
    }
}

private struct PhoneControlSettingsRow: View {
    let layout: PhoneControlLayout
    let button: PhoneControlButton
    let index: Int
    @Bindable var store: PhoneControlsStore
    let onEditMacro: (Macro, (layoutID: UUID, buttonID: UUID)?) -> Void

    @State private var showingIconPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())

                Button {
                    showingIconPicker = true
                } label: {
                    Image(systemName: button.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Choose icon")

                TextField("Label", text: labelBinding)
                    .textFieldStyle(.roundedBorder)

                Toggle("Large", isOn: prominentBinding)
                    .toggleStyle(.checkbox)
                    .help("Show this as the one big button on the phone")

                Button { store.moveButton(layoutID: layout.id, buttonID: button.id, by: -1) } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move left")
                Button { store.moveButton(layoutID: layout.id, buttonID: button.id, by: 1) } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == layout.buttons.count - 1)
                .help("Move right")
                Button(role: .destructive) { store.removeButton(layoutID: layout.id, buttonID: button.id) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(layout.buttons.count == 1)
                .help("Remove button")
            }

            // Lines up under the row above: the label spans the badge and icon column, the
            // kind picker starts where the label field starts, and the detail control is
            // always the same 130pt menu whatever the kind.
            HStack(spacing: 10) {
                Text("Action")
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Picker("Action", selection: actionKindBinding) {
                    ForEach(PhoneControlAction.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 138)

                actionDetail
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .disabled(layout.isBuiltIn)
        .sheet(isPresented: $showingIconPicker) {
            PhoneSymbolPickerView(selectedSymbol: button.symbol) { symbol in
                store.updateButton(layoutID: layout.id, buttonID: button.id) { $0.symbol = symbol }
            }
        }
    }

    @ViewBuilder
    private var actionDetail: some View {
        switch button.action {
        case .key(let keyCode, let modifiers):
            PhoneShortcutRecorderView(keyCode: keyCode, modifiers: modifiers, quickKeys: Self.quickKeys) { keyCode, modifiers in
                store.updateButton(layoutID: layout.id, buttonID: button.id) {
                    $0.action = .key(keyCode: keyCode, modifiers: modifiers)
                }
            }
        case .mediaKey(let kind):
            Picker("Media key", selection: Binding(
                get: { kind },
                set: { newKind in
                    store.updateButton(layoutID: layout.id, buttonID: button.id) {
                        $0.action = .mediaKey(newKind)
                    }
                }
            )) {
                ForEach(MediaKeyKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
        case .macro(let macroID):
            macroPicker(macroID: macroID)
        case .textInput:
            Spacer(minLength: 0)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help("Tap this button on the phone and Beam asks you for text. Beacon types that text into the app that has keyboard focus on the Mac, then presses Return.")
        case .none:
            Spacer(minLength: 0)
            Text("No action")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func macroPicker(macroID: UUID) -> some View {
        // Same 130pt menu as the other actions; New and Edit live inside it so nothing else
        // needs room on the row.
        let newTag = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let editTag = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        return Picker("Macro", selection: Binding(
            get: { macroID },
            set: { selected in
                if selected == newTag {
                    makeMacro()
                } else if selected == editTag {
                    if let macro = store.macro(id: macroID) {
                        onEditMacro(macro, (layout.id, button.id))
                    }
                } else {
                    store.updateButton(layoutID: layout.id, buttonID: button.id) {
                        $0.action = .macro(id: selected)
                    }
                }
            }
        )) {
            if store.macro(id: macroID) == nil {
                Text("Choose macro").tag(macroID)
            }
            ForEach(store.macros) { macro in
                Text(macro.name).tag(macro.id)
            }
            Divider()
            Text("New macro…").tag(newTag)
            if store.macro(id: macroID) != nil {
                Text("Edit macro…").tag(editTag)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { button.label },
            set: { value in
                store.updateButton(layoutID: layout.id, buttonID: button.id) { $0.label = value }
            }
        )
    }

    private var prominentBinding: Binding<Bool> {
        Binding(
            get: { button.prominent },
            set: { store.setProminent(layoutID: layout.id, buttonID: button.id, isProminent: $0) }
        )
    }

    private var actionKindBinding: Binding<PhoneControlAction.Kind> {
        Binding(
            get: { button.action.kind },
            set: { kind in
                if kind == .macro {
                    if let macro = store.macros.first {
                        store.updateButton(layoutID: layout.id, buttonID: button.id) { $0.action = .macro(id: macro.id) }
                    } else {
                        makeMacro()
                    }
                } else {
                    store.updateButton(layoutID: layout.id, buttonID: button.id) {
                        $0.action = button.action.replacingKind(kind)
                    }
                }
            }
        )
    }

    private func makeMacro() {
        onEditMacro(
            Macro(id: UUID(), name: "New Macro", steps: []),
            (layout.id, button.id)
        )
    }

    private static let quickKeys = [
        QuickKey(title: "Left", keyCode: UInt32(kVK_LeftArrow), modifiers: 0),
        QuickKey(title: "Right", keyCode: UInt32(kVK_RightArrow), modifiers: 0),
        QuickKey(title: "Up", keyCode: UInt32(kVK_UpArrow), modifiers: 0),
        QuickKey(title: "Down", keyCode: UInt32(kVK_DownArrow), modifiers: 0),
        QuickKey(title: "Space", keyCode: UInt32(kVK_Space), modifiers: 0),
        QuickKey(title: "J", keyCode: UInt32(kVK_ANSI_J), modifiers: 0),
        QuickKey(title: "K", keyCode: UInt32(kVK_ANSI_K), modifiers: 0),
        QuickKey(title: "L", keyCode: UInt32(kVK_ANSI_L), modifiers: 0),
        QuickKey(title: "Shift+Left", keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(shiftKey)),
        QuickKey(title: "Shift+Right", keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(shiftKey))
    ]
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

struct QuickKey {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
}

/// One control for a key action, drawn as the same 130pt menu picker the other actions use.
/// The list is the current key, "Record key…" and the common keys; while recording it turns
/// into an orange button until a key is pressed (Esc cancels).
private struct PhoneShortcutRecorderView: View {
    let keyCode: UInt32
    let modifiers: UInt32
    let quickKeys: [QuickKey]
    let onChange: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    private static let recordTag = "__record__"
    private var currentTag: String { "\(keyCode):\(modifiers)" }
    private func tag(_ key: QuickKey) -> String { "\(key.keyCode):\(key.modifiers)" }

    var body: some View {
        Group {
            if isRecording {
                Button { stopRecording() } label: {
                    Text("Press a key…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                Picker("Key", selection: Binding(
                    get: { currentTag },
                    set: { selected in
                        if selected == Self.recordTag {
                            startRecording()
                        } else if let key = quickKeys.first(where: { tag($0) == selected }) {
                            onChange(key.keyCode, key.modifiers)
                        }
                    }
                )) {
                    if !quickKeys.contains(where: { tag($0) == currentTag }) {
                        Text(phoneControlDisplayString(keyCode: keyCode, modifiers: modifiers)).tag(currentTag)
                    }
                    ForEach(quickKeys, id: \.title) { key in
                        Text(key.title).tag(tag(key))
                    }
                    Divider()
                    Text("Record key…").tag(Self.recordTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        .frame(maxWidth: .infinity)
        .help("Pick a common key or record any key or shortcut")
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

private struct LayoutNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialName: String
    let onSave: (String) -> Void
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Layout name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 330)
    }
}

private struct MacroEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let macro: Macro
    let onSave: (Macro) -> Void

    @State private var name: String
    @State private var recorder: MacroEventRecorder
    @State private var isPreviewing = false
    @State private var previewKeys = Set<UInt32>()
    @State private var previewTask: Task<Void, Never>?

    init(macro: Macro, onSave: @escaping (Macro) -> Void) {
        self.macro = macro
        self.onSave = onSave
        _name = State(initialValue: macro.name)
        _recorder = State(initialValue: MacroEventRecorder(initialSteps: macro.steps))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Macro editor")
                    .font(.title3.weight(.semibold))
                Spacer()
                Toggle("Preview", isOn: $isPreviewing)
                    .toggleStyle(.switch)
                    .disabled(recorder.steps.isEmpty || recorder.isRecording)
            }

            HStack(spacing: 10) {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("Macro name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if !AXIsProcessTrusted() {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Accessibility access is required to record macros.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Grant Access…") { requestPhoneControlAccessibilityPermission() }
                        .buttonStyle(.link)
                }
            }

            VirtualKeyboardView(heldKeyCodes: isPreviewing ? previewKeys : recorder.heldKeyCodes)

            HStack {
                Label(
                    "\(recorder.steps.count) \(recorder.steps.count == 1 ? "step" : "steps")",
                    systemImage: "list.number"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { recorder.clear() }
                    .buttonStyle(.borderless)
                    .disabled(recorder.steps.isEmpty || recorder.isRecording)
                Button(recorder.isRecording ? "Stop" : "Record") {
                    recorder.isRecording ? recorder.stop() : recorder.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .orange : nil)
                .disabled(!recorder.isRecording && !AXIsProcessTrusted())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if recorder.steps.isEmpty {
                            Text("Press Record, then type the keys to replay. Recording stops after 10 seconds without a key, or with Esc.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(recorder.steps.enumerated()), id: \.offset) { index, step in
                                HStack(spacing: 8) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(macroStepDescription(step))
                                        .font(.callout.monospaced())
                                    Text(index == 0 ? "starts immediately" : "after \(step.delayMs) ms")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 142)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .foregroundStyle(.black)
                }
                .buttonStyle(.bordered)
                Button("Save") {
                    recorder.stop()
                    onSave(Macro(
                        id: macro.id,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Macro" : name,
                        steps: recorder.steps
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 670)
        .onChange(of: isPreviewing) { _, enabled in
            enabled ? startPreview() : stopPreview()
        }
        .onDisappear {
            recorder.stop()
            stopPreview()
        }
    }

    private func startPreview() {
        previewTask?.cancel()
        previewKeys.removeAll()
        let steps = recorder.steps
        previewTask = Task { @MainActor in
            while !Task.isCancelled {
                for step in steps {
                    if step.delayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(step.delayMs) * 1_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        applyPreview(step)
                    }
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    previewKeys.removeAll()
                }
                // A beat between loops so the start of the macro reads as a start.
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewKeys.removeAll()
    }

    private func applyPreview(_ step: MacroStep) {
        switch step {
        case .keyDown(let keyCode, _, _): previewKeys.insert(keyCode)
        case .keyUp(let keyCode, _, _): previewKeys.remove(keyCode)
        }
    }
}

@Observable
private final class MacroEventRecorder {
    var steps: [MacroStep]
    var isRecording = false
    var heldKeyCodes = Set<UInt32>()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var idleTimer: Timer?
    private var lastStepTime: TimeInterval?

    init(initialSteps: [MacroStep]) {
        steps = initialSteps
    }

    func start() {
        guard AXIsProcessTrusted(), !isRecording else { return }
        isRecording = true
        lastStepTime = nil
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async { self?.record(event) }
        }
        // Swallow local key events: while recording, keys must not also type into the sheet.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
            return nil
        }
        armIdleTimer()
    }

    func stop() {
        guard isRecording || globalMonitor != nil || localMonitor != nil else { return }
        isRecording = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        lastStepTime = nil
        heldKeyCodes.removeAll()
    }

    func clear() {
        steps.removeAll()
        lastStepTime = nil
    }

    private func record(_ event: NSEvent) {
        guard isRecording else { return }
        if event.type == .keyDown, event.keyCode == 53 {
            stop()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        armIdleTimer()
        let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
        switch event.type {
        case .keyDown:
            heldKeyCodes.insert(UInt32(event.keyCode))
            append(.keyDown(keyCode: UInt32(event.keyCode), modifiers: modifiers, delayMs: delay(at: now)), at: now)
        case .keyUp:
            heldKeyCodes.remove(UInt32(event.keyCode))
            append(.keyUp(keyCode: UInt32(event.keyCode), modifiers: modifiers, delayMs: delay(at: now)), at: now)
        case .flagsChanged:
            let keyCode = UInt32(event.keyCode)
            if modifierIsDown(for: event) {
                heldKeyCodes.insert(keyCode)
                append(.keyDown(keyCode: keyCode, modifiers: modifiers, delayMs: delay(at: now)), at: now)
            } else {
                heldKeyCodes.remove(keyCode)
                append(.keyUp(keyCode: keyCode, modifiers: modifiers, delayMs: delay(at: now)), at: now)
            }
        default:
            break
        }
    }

    private func append(_ step: MacroStep, at time: TimeInterval) {
        steps.append(step)
        lastStepTime = time
    }

    private func delay(at time: TimeInterval) -> UInt32 {
        guard let lastStepTime else { return 0 }
        let milliseconds = max(0, min((time - lastStepTime) * 1_000, Double(UInt32.max)))
        return UInt32(milliseconds.rounded())
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    private func modifierIsDown(for event: NSEvent) -> Bool {
        switch event.keyCode {
        case 54, 55: return event.modifierFlags.contains(.command)
        case 56, 60: return event.modifierFlags.contains(.shift)
        case 58, 61: return event.modifierFlags.contains(.option)
        case 59, 62: return event.modifierFlags.contains(.control)
        case 57: return event.modifierFlags.contains(.capsLock)
        case 63: return event.modifierFlags.contains(.function)
        default: return false
        }
    }

}

private struct VirtualKeyboardView: View {
    let heldKeyCodes: Set<UInt32>

    struct Key: Identifiable {
        let keyCode: UInt32
        let label: String
        let width: CGFloat
        var id: UInt32 { keyCode }
    }

    private static let rows: [[Key]] = [
        [key(53, "esc"), key(122, "F1"), key(120, "F2"), key(99, "F3"), key(118, "F4"), key(96, "F5"), key(97, "F6"), key(98, "F7"), key(100, "F8"), key(101, "F9"), key(109, "F10"), key(103, "F11"), key(111, "F12"), key(105, "F13")],
        [key(50, "`"), key(18, "1"), key(19, "2"), key(20, "3"), key(21, "4"), key(23, "5"), key(22, "6"), key(26, "7"), key(28, "8"), key(25, "9"), key(29, "0"), key(27, "-"), key(24, "="), key(51, "delete", 1.7)],
        [key(48, "tab", 1.5), key(12, "Q"), key(13, "W"), key(14, "E"), key(15, "R"), key(17, "T"), key(16, "Y"), key(32, "U"), key(34, "I"), key(31, "O"), key(35, "P"), key(33, "["), key(30, "]"), key(42, "\\", 1.2)],
        [key(57, "caps", 1.8), key(0, "A"), key(1, "S"), key(2, "D"), key(3, "F"), key(5, "G"), key(4, "H"), key(38, "J"), key(40, "K"), key(37, "L"), key(41, ";"), key(39, "'"), key(36, "return", 1.9)],
        [key(56, "shift", 2.3), key(6, "Z"), key(7, "X"), key(8, "C"), key(9, "V"), key(11, "B"), key(45, "N"), key(46, "M"), key(43, ","), key(47, "."), key(44, "/"), key(60, "shift", 2.4)],
        [key(63, "fn", 1.1), key(59, "ctrl", 1.2), key(58, "opt", 1.2), key(55, "cmd", 1.3), key(49, "space", 4.6), key(54, "cmd", 1.3), key(61, "opt", 1.2), key(123, "←"), key(125, "↓"), key(124, "→")]
    ]

    private static var knownKeyCodes: Set<UInt32> {
        Set(rows.flatMap { $0.map(\.keyCode) })
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(spacing: 4) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    KeyboardRow(keys: row, heldKeyCodes: heldKeyCodes)
                }
                let unknownCodes = heldKeyCodes.subtracting(Self.knownKeyCodes).sorted()
                if !unknownCodes.isEmpty {
                    HStack(spacing: 4) {
                        Text("Other")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(unknownCodes, id: \.self) { keyCode in
                            KeyCap(label: "Key \(keyCode)", width: 1.4, isHeld: true)
                        }
                        Spacer()
                    }
                    .padding(.top, 3)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private static func key(_ keyCode: UInt32, _ label: String, _ width: CGFloat = 1) -> Key {
        Key(keyCode: keyCode, label: label, width: width)
    }
}

private struct KeyboardRow: View {
    let keys: [VirtualKeyboardView.Key]
    let heldKeyCodes: Set<UInt32>

    var body: some View {
        GeometryReader { geometry in
            let spacing = CGFloat(4)
            let totalWidth = keys.reduce(CGFloat(0)) { $0 + $1.width }
            let unit = (geometry.size.width - spacing * CGFloat(keys.count - 1)) / totalWidth
            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    KeyCap(label: key.label, width: unit * key.width, isHeld: heldKeyCodes.contains(key.keyCode))
                }
            }
        }
        .frame(height: 30)
    }
}

private struct KeyCap: View {
    let label: String
    let width: CGFloat
    let isHeld: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(isHeld ? .white : .primary)
            .lineLimit(1)
            .frame(width: width, height: 30)
            .background(isHeld ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isHeld ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

private func macroStepDescription(_ step: MacroStep) -> String {
    switch step {
    case .keyDown(let keyCode, let modifiers, _):
        return phoneControlDisplayString(keyCode: keyCode, modifiers: modifiers)
    case .keyUp(let keyCode, let modifiers, _):
        return "\(phoneControlDisplayString(keyCode: keyCode, modifiers: modifiers)) up"
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
