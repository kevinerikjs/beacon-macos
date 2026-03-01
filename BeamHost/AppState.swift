// AppState.swift
// Central observable app state - single source of truth for the entire macOS host app.

import SwiftUI
import ScreenCaptureKit

@Observable
final class AppState {

    /// App-wide singleton reference set during initialization.
    /// Used by subsystems (PairingManager) that don't have environment access.
    static weak var shared: AppState?

    // MARK: - Stream State

    /// Whether the host is actively streaming to a client.
    var isStreaming: Bool = false

    /// Name of the currently connected iPhone, if any.
    var connectedDeviceName: String? = nil

    // MARK: - Capture Configuration

    /// All available displays, populated after permission is granted.
    var availableDisplays: [SCDisplay] = []

    /// Index into `availableDisplays` for the display being streamed.
    var selectedDisplayIndex: Int = 0 {
        didSet {
            UserDefaults.standard.set(selectedDisplayIndex, forKey: "selectedDisplayIndex")
            if isStreaming {
                Task { await streamServer?.switchDisplay() }
            }
        }
    }

    /// Whether Screen Recording permission has been granted.
    var hasCapturePermission: Bool = false

    /// Whether Accessibility permission has been granted (needed for media key forwarding).
    var hasAccessibilityPermission: Bool {
        MediaKeyDispatcher.isAccessibilityGranted
    }

    // MARK: - Pairing

    /// All devices that have been paired with this Mac.
    var pairedDevices: [PairedDevice] = []

    // MARK: - Preferences

    /// Whether Beam should launch when the user logs in.
    var launchAtLogin: Bool = true {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            LoginItemManager.shared.setEnabled(launchAtLogin)
        }
    }
    // MARK: - Quality

    let qualityManager = VideoQualityManager()

    // MARK: - Window Streaming

    /// Whether we're streaming a specific window instead of the full display.
    var isWindowMode: Bool = false

    /// Available on-screen windows for the window picker.
    var availableWindows: [SCWindow] = []

    // MARK: - Connection

    /// The stream server - handles both connection acceptance and Bonjour advertising.
    private(set) var streamServer: StreamServer?

    // MARK: - Initializer

    init() {
        AppState.shared = self

        // Restore preferences
        selectedDisplayIndex = UserDefaults.standard.integer(forKey: "selectedDisplayIndex")
        if UserDefaults.standard.object(forKey: "launchAtLogin") != nil {
            launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        }

        // Load paired devices from keychain
        pairedDevices = KeyStore.shared.loadPairedDevices()

        // Start the server pipeline
        Task { await startServer() }
    }

    // MARK: - Server Lifecycle

    @MainActor
    func startServer() async {
        // Check / request Screen Recording permission
        hasCapturePermission = await ScreenCapture.requestPermission()

        guard hasCapturePermission else { return }

        // Enumerate displays
        availableDisplays = await ScreenCapture.availableDisplays()

        // Clamp index in case display count changed since last run
        if selectedDisplayIndex >= availableDisplays.count {
            selectedDisplayIndex = 0
        }

        // Start the stream server (Bonjour advertising is handled inside StreamServer)
        let server = StreamServer(appState: self, qualityManager: qualityManager)
        self.streamServer = server
        server.start()
    }

    // MARK: - Streaming Control

    @MainActor
    func stopStreaming() {
        streamServer?.disconnectAllClients()
    }

    // MARK: - Window Streaming

    func refreshAvailableWindows() async {
        availableWindows = await ScreenCapture.availableWindows()
    }

    @MainActor
    func beamWindow(_ window: SCWindow) async {
        guard let server = streamServer else { return }
        await server.switchToWindowMode(window: window)
        isWindowMode = true
    }

    @MainActor
    func beamFullDisplay() async {
        guard let server = streamServer else { return }
        await server.switchToDisplayMode()
        isWindowMode = false
    }

    // MARK: - Pairing

    func unpairDevice(id: String) {
        // Notify the device while it's still connected, then disconnect it
        streamServer?.notifyUnpaired(deviceID: id)
        pairedDevices.removeAll { $0.id == id }
        KeyStore.shared.savePairedDevices(pairedDevices)
    }

    /// The display currently selected for streaming.
    var selectedDisplay: SCDisplay? {
        guard availableDisplays.indices.contains(selectedDisplayIndex) else { return nil }
        return availableDisplays[selectedDisplayIndex]
    }
}

// MARK: - PairedDevice

struct PairedDevice: Codable, Identifiable {
    let id: String        // UUID string
    let name: String      // e.g. "Kevin's iPhone"
    let sharedSecret: Data
    var lastSeen: Date
}
