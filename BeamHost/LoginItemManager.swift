// LoginItemManager.swift
// Manages "Launch at Login" using ServiceManagement (SMAppService).
// This is the modern macOS 13+ approach - no helper app needed.

import ServiceManagement
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "LoginItem")

final class LoginItemManager {

    static let shared = LoginItemManager()
    private init() {}

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    logger.info("Registered launch at login")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    logger.info("Unregistered launch at login")
                }
            }
        } catch {
            logger.error("Failed to update login item: \(error)")
        }
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
