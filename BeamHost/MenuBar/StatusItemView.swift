// StatusItemView.swift
// The dropdown menu content shown when the user clicks the menu bar icon.

import SwiftUI
import ScreenCaptureKit
import AppKit
import Sparkle

struct StatusItemView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    let updater: SPUUpdater

    var body: some View {
        // Status header
        statusSection

        Divider()

        // Display picker
        displaySection

        Divider()

        // Window streaming mode
        windowModeSection

        Divider()

        // Paired devices
        pairedDevicesSection

        Divider()

        Button("Preferences…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }

        Button("Quit Beacon") {
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
                VStack(alignment: .leading, spacing: 1) {
                    Text("Streaming to \(device)")
                        .font(.callout)
                    HStack(spacing: 4) {
                        Text(appState.qualityManager.activePreset.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if appState.isWindowMode {
                            Text("· Window mode")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
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

    // MARK: - Window Mode Section

    @ViewBuilder
    private var windowModeSection: some View {
        Text("Stream Mode")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 2)

        Button("Beam a Specific Window…") {
            openWindowPicker()
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

    private func openWindowPicker() {
        WindowPickerWindowController.shared.show(appState: appState)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Window Picker Window

@MainActor
final class WindowPickerWindowController: NSWindowController {
    static let shared = WindowPickerWindowController()
    private static let defaultContentSize = NSSize(width: 980, height: 660)
    private static let minimumContentSize = NSSize(width: 820, height: 520)

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(appState: AppState) {
        let root = WindowPickerView(appState: appState, closeAction: { [weak self] in
            self?.hide()
        })

        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<WindowPickerView> {
                hostingController.rootView = root
            } else {
                window.contentViewController = NSHostingController(rootView: root)
            }
            enforceUsableWindowSize(window)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
        } else {
            let hostingController = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "Beam a Specific Window"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.contentMinSize = Self.minimumContentSize
            newWindow.setContentSize(Self.defaultContentSize)
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            self.window = newWindow
        }

        window?.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func enforceUsableWindowSize(_ window: NSWindow) {
        window.contentMinSize = Self.minimumContentSize
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let isTooSmall = currentContentSize.width < Self.minimumContentSize.width
            || currentContentSize.height < Self.minimumContentSize.height
        if isTooSmall {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
    }
}

// MARK: - Window Picker View

private struct WindowPreviewCard: Identifiable {
    let id: CGWindowID
    let window: SCWindow
    let title: String
    let appName: String
    let image: NSImage?
}

@MainActor
private struct WindowPickerView: View {
    let appState: AppState
    let closeAction: () -> Void

    @State private var cards: [WindowPreviewCard] = []
    private let timer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()
    private let columns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share a specific window")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Pick a window below. Previews refresh continuously.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { closeAction() }
                    .buttonStyle(.bordered)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    fullDisplayCard
                    ForEach(cards) { card in
                        windowCard(card)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(22)
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.09, blue: 0.11),
                    Color(red: 0.06, green: 0.06, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear { refreshCards() }
        .onReceive(timer) { _ in refreshCards() }
    }

    private var fullDisplayCard: some View {
        Button {
            Task {
                await appState.beamFullDisplay()
                closeAction()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.04))
                    Image(systemName: "display.2")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .frame(height: 220)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Full Display")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Stream the entire selected display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(cardBackground(isActive: !appState.isWindowMode))
        }
        .buttonStyle(.plain)
    }

    private func windowCard(_ card: WindowPreviewCard) -> some View {
        Button {
            Task {
                await appState.beamWindow(card.window)
                closeAction()
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.35))
                    if let image = card.image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(10)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 220)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    Text(card.appName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(cardBackground(isActive: false))
        }
        .buttonStyle(.plain)
    }

    private func cardBackground(isActive: Bool) -> some ShapeStyle {
        LinearGradient(
            colors: isActive
                ? [Color.orange.opacity(0.35), Color.orange.opacity(0.12)]
                : [Color.white.opacity(0.09), Color.white.opacity(0.03)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func refreshCards() {
        Task {
            let windows = await ScreenCapture.availableWindows()
            let freshCards = windows.compactMap { window -> WindowPreviewCard? in
                guard let appName = window.owningApplication?.applicationName else { return nil }
                let title = (window.title?.isEmpty == false) ? window.title! : appName
                return WindowPreviewCard(
                    id: window.windowID,
                    window: window,
                    title: title,
                    appName: appName,
                    image: capturePreview(for: window.windowID)
                )
            }
            cards = Array(freshCards.prefix(16))
        }
    }

    private func capturePreview(for windowID: CGWindowID) -> NSImage? {
        guard let imageRef = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }
        return NSImage(cgImage: imageRef, size: .zero)
    }
}
