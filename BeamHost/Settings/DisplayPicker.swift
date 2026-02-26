// DisplayPicker.swift
// Reusable display selection component used in the menu bar dropdown.
// Wraps the ScreenCaptureKit SCDisplay list.

import SwiftUI
import ScreenCaptureKit

/// A simple inline display picker showing available displays with a checkmark
/// on the currently selected one.
struct DisplayPickerMenuItems: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ForEach(Array(appState.availableDisplays.enumerated()), id: \.offset) { index, display in
            Button {
                appState.selectedDisplayIndex = index
            } label: {
                HStack {
                    Text(displayLabel(for: display, index: index))
                    if appState.selectedDisplayIndex == index {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func displayLabel(for display: SCDisplay, index: Int) -> String {
        let dimensions = "\(display.width) × \(display.height)"
        let prefix = index == 0 ? "Main Display" : "Display \(index + 1)"
        return "\(prefix) (\(dimensions))"
    }
}
