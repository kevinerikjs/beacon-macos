// PairingWindowController.swift
// NSWindowController that hosts the pairing QR code / manual code entry view.

import AppKit
import SwiftUI

final class PairingWindowController: NSWindowController {

    static let shared = PairingWindowController()

    private init() {
        let contentView = PairingView()
            .environment(PairingManager.shared)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 360, height: 480)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Pair a New Device"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func close() {
        window?.orderOut(nil)
    }
}

// MARK: - PairingView

struct PairingView: View {
    @Environment(PairingManager.self) private var pairingManager

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Pair Your iPhone")
                    .font(.title2.weight(.semibold))
                Text("Open Beam on your iPhone and enter the code shown below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if pairingManager.isPairingActive {
                activePairingContent
            } else {
                waitingForIPhoneContent
            }

            Spacer()

            Button("Cancel") {
                pairingManager.cancelPairing()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 360, height: 480)
    }

    // MARK: - Sub-Views

    @ViewBuilder
    private var activePairingContent: some View {
        VStack(spacing: 12) {
            if let code = pairingManager.currentCode {
                let formatted = "\(code.prefix(3)) \(code.suffix(3))"
                Text(formatted)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(.primary)
            }
            Text("Enter this code in the Beam app on your iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var waitingForIPhoneContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()
            Text("Waiting for iPhone to initiate pairing…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
