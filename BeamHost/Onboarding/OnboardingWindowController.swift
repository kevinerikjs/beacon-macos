// OnboardingWindowController.swift
// Hosts the first-launch onboarding experience in a floating panel.

import AppKit
import SwiftUI

final class OnboardingWindowController: NSWindowController {

    static let shared = OnboardingWindowController()

    private init() {
        // Build a proper window up front so super.init(window:) is satisfied.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.043, alpha: 1) // #0a0a0b
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func close() {
        window?.orderOut(nil)
        BeaconAppDelegate.syncActivationPolicy()
    }

    func present(appState: AppState) {
        let content = OnboardingView().environment(appState)
        let hosting = NSHostingController(rootView: content)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 540, height: 580)

        window?.contentViewController = hosting
        window?.contentView?.wantsLayer = true
        window?.contentView?.layer?.cornerRadius = 14
        window?.contentView?.layer?.masksToBounds = true
        window?.setContentSize(NSSize(width: 540, height: 580))
        window?.center()

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
