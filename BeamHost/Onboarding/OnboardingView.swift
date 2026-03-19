// OnboardingView.swift
// First-launch onboarding: permissions setup + pairing guide.
// Shown once when the app is launched for the first time.

import SwiftUI
import ScreenCaptureKit
import AppKit

// MARK: - Brand Colors

private extension Color {
    static let beamAmber          = Color(red: 245/255, green: 158/255, blue: 11/255)   // #f59e0b
    static let beamOrange         = Color(red: 249/255, green: 115/255, blue: 22/255)   // #f97316
    static let beamBg             = Color(red: 10/255,  green: 10/255,  blue: 11/255)   // #0a0a0b
    static let beamSurface        = Color(red: 17/255,  green: 17/255,  blue: 20/255)   // #111114
    static let beamCard           = Color(red: 30/255,  green: 30/255,  blue: 36/255)   // #1e1e24
    static let beamBorder         = Color(red: 42/255,  green: 42/255,  blue: 51/255)   // #2a2a33
    static let beamText           = Color(red: 240/255, green: 240/255, blue: 242/255)  // #f0f0f2
    static let beamTextSecondary  = Color(red: 136/255, green: 136/255, blue: 160/255)  // #8888a0
}

// MARK: - OnboardingView (root, fixed 540 × 580)

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var step: OnboardingStep = .permissions

    enum OnboardingStep { case permissions, pairing }

    var body: some View {
        ZStack {
            Color.beamBg.ignoresSafeArea()

            GeometryReader { geo in
                RadialGradient(
                    colors: [Color.beamAmber.opacity(0.07), Color.clear],
                    center: .top, startRadius: 0,
                    endRadius: geo.size.width * 0.9
                )
                .ignoresSafeArea()
            }

            Group {
                switch step {
                case .permissions:
                    PermissionsStepView {
                        withAnimation(.easeInOut(duration: 0.4)) { step = .pairing }
                    }
                case .pairing:
                    PairingGuideStepView()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .frame(width: 540, height: 580)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStepView: View {
    @Environment(AppState.self) private var appState
    @State private var requestingPermission = false
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // ── Top flex space ─────────────────────────────────────────────
            Spacer()

            // Header
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.beamAmber.opacity(0.28), radius: 16, y: 4)

                Text("Welcome to Beacon")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.beamText)

                Text("Beacon needs a couple of permissions before you can start streaming.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.beamTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Spacer().frame(height: 28)

            // Permission rows
            VStack(spacing: 10) {
                PermissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    subtitle: "Required to capture your display and stream it to your iPhone.",
                    badge: nil,
                    isGranted: appState.hasCapturePermission,
                    isLoading: requestingPermission && !appState.hasCapturePermission
                ) {
                    requestingPermission = true
                    Task { @MainActor in
                        let granted = await ScreenCapture.requestPermission()
                        appState.hasCapturePermission = granted
                        requestingPermission = false
                        if granted { await appState.startServer() }
                    }
                }

                PermissionRow(
                    icon: "keyboard",
                    title: "Media Key Control",
                    subtitle: "Lets your iPhone control Mac playback: pause, skip, and seek.",
                    badge: "Optional",
                    isGranted: appState.hasAccessibilityPermission,
                    isLoading: false
                ) {
                    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
                    AXIsProcessTrustedWithOptions(opts as CFDictionary)
                }
            }
            .padding(.horizontal, 28)

            // ── Bottom flex space ──────────────────────────────────────────
            Spacer()

            // Continue button pinned to bottom
            Button(action: onContinue) {
                HStack(spacing: 7) {
                    Text("Continue")
                        .font(.system(size: 14.5, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(
                    appState.hasCapturePermission
                        ? Color(red: 26/255, green: 14/255, blue: 0)
                        : Color.beamTextSecondary
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Group {
                        if appState.hasCapturePermission {
                            LinearGradient(
                                colors: [Color.beamAmber, Color.beamOrange],
                                startPoint: .leading, endPoint: .trailing
                            )
                        } else {
                            Color.beamCard
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(
                    color: appState.hasCapturePermission ? Color.beamAmber.opacity(0.35) : .clear,
                    radius: 10, y: 3
                )
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasCapturePermission)
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .frame(width: 540, height: 580)
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    let isGranted: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.beamCard)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isGranted ? Color.beamAmber : Color.beamTextSecondary)
            }

            // Text — takes all remaining width before the trailing button
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.beamText)
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.beamTextSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.beamCard))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.beamTextSecondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status / action — fixed width so it never squishes the text
            Group {
                if isGranted {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Enabled")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Color.beamAmber)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.beamAmber.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.beamAmber.opacity(0.25), lineWidth: 0.5)
                            )
                    )
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 88)
                } else {
                    Button(action: action) {
                        Text("Grant Access")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.beamText.opacity(0.85))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.beamCard)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(Color.beamBorder, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .fixedSize()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.beamSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isGranted ? Color.beamAmber.opacity(0.2) : Color.beamBorder,
                            lineWidth: 0.5
                        )
                )
        )
    }
}

// MARK: - Step 2: Pairing Guide

private struct PairingGuideStepView: View {
    @Environment(AppState.self) private var appState
    private let appStoreURL = URL(string: "https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962")!

    var body: some View {
        VStack(spacing: 0) {

            // Header
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .shadow(color: Color.beamAmber.opacity(0.28), radius: 14, y: 4)

                Text("Connect Your iPhone")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.beamText)

                Text("Pair once. Beam reconnects automatically whenever you're on the same Wi-Fi.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.beamTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 36)
            .padding(.bottom, 20)

            // Steps card
            VStack(spacing: 0) {
                StepRow(
                    number: 1,
                    icon: "arrow.down.app.fill",
                    title: "Download Beam on your iPhone",
                    description: "The free Beam app is available on the App Store.",
                    accessoryURL: appStoreURL
                )

                Divider().overlay(Color.beamBorder).padding(.leading, 60)

                StepRow(
                    number: 2,
                    icon: "wifi",
                    title: "Same Wi-Fi network",
                    description: "Make sure your iPhone and Mac are on the same local network.",
                    accessoryURL: nil
                )

                Divider().overlay(Color.beamBorder).padding(.leading, 60)

                StepRow(
                    number: 3,
                    icon: "iphone.and.arrow.forward",
                    title: "Open Beam and tap your Mac",
                    description: "Beam auto-discovers Beacon. Tap your Mac's name to connect.",
                    accessoryURL: nil
                )

                Divider().overlay(Color.beamBorder).padding(.leading, 60)

                StepRow(
                    number: 4,
                    icon: "lock.open.fill",
                    title: "Enter the 6-digit code",
                    description: "A code appears in Beacon's menu. Type it into Beam to pair.",
                    accessoryURL: nil
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.beamSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.beamBorder, lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 28)

            // Security note
            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.beamAmber.opacity(0.7))
                Text("New devices always require authorization. You control who can see your screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.beamTextSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Spacer()

            // CTA
            VStack(spacing: 10) {
                Button(action: {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    OnboardingWindowController.shared.close()
                    PairingWindowController.shared.showWindow(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    HStack(spacing: 7) {
                        Text("Pair My iPhone Now")
                            .font(.system(size: 14.5, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color(red: 26/255, green: 14/255, blue: 0))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        LinearGradient(
                            colors: [Color.beamAmber, Color.beamOrange],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color.beamAmber.opacity(0.35), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)

                Button(action: {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    OnboardingWindowController.shared.close()
                }) {
                    Text("Skip for now")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.beamTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 28)
        }
        .frame(width: 540, height: 580)
    }
}

// MARK: - Step Row

private struct StepRow: View {
    let number: Int
    let icon: String
    let title: String
    let description: String
    let accessoryURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(Color.beamAmber.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.beamAmber)
            }

            // Text block — takes all remaining width
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.beamText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.beamTextSecondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = accessoryURL {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 10))
                            Text("App Store")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.beamText.opacity(0.8))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.beamCard)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.beamBorder, lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Step number pill
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.beamTextSecondary.opacity(0.5))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.beamCard))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
