// MacFeedbackView.swift
// Feedback sheet for Beacon (macOS). Posts to beamscreen.app/api/feedback.

import SwiftUI

struct MacFeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var email = ""
    @State private var status: Status = .idle

    enum Status { case idle, sending, success, failed }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if status == .success {
                successView
            } else {
                formView
            }
        }
        .frame(width: 400)
        .padding(24)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Feedback")
                .font(.headline)

            Text("Your feedback goes straight to the developer.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Email (optional — if you'd like a reply)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
            }

            if case .failed = status {
                Text("Couldn't send — check your connection and try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send Feedback") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
                if status == .sending {
                    ProgressView().scaleEffect(0.7)
                }
            }
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            VStack(spacing: 6) {
                Text("Thanks!")
                    .font(.headline)
                Text("Your feedback was sent.")
                    .foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Send

    private func send() {
        guard canSend else { return }
        status = .sending

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                guard let url = URL(string: "https://beamscreen.app/api/feedback") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Injected at build time from the BEAM_FEEDBACK_SECRET build setting, so it stays
                // out of the source tree. Absent in contributor builds, which is fine: the server
                // accepts unsigned feedback and only uses this to mark a report as coming from an
                // official build.
                if let secret = Bundle.main.object(forInfoDictionaryKey: "BeamFeedbackSecret") as? String,
                   !secret.isEmpty {
                    req.setValue(secret, forHTTPHeaderField: "X-Beam-Secret")
                }
                var payload: [String: String] = ["message": trimmedMessage, "source": "macos"]
                if !trimmedEmail.isEmpty { payload["email"] = trimmedEmail }
                req.httpBody = try JSONEncoder().encode(payload)

                let (_, response) = try await URLSession.shared.data(for: req)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200

                await MainActor.run { status = ok ? .success : .failed }
            } catch {
                await MainActor.run { status = .failed }
            }
        }
    }
}
