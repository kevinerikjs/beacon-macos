// KeyStore.swift
// Persists paired device credentials in the macOS Keychain.
// Keychain survives app deletion and reinstall, which is intentional for
// pairing continuity (user doesn't have to re-pair after reinstalling macOS app).

import Foundation
import Security
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "KeyStore")

final class KeyStore {

    static let shared = KeyStore()
    private init() {}

    private let service = "com.beam.host"
    private let pairedDevicesKey = "paired_devices"

    // MARK: - Paired Devices

    func loadPairedDevices() -> [PairedDevice] {
        guard let data = load(key: pairedDevicesKey) else { return [] }
        do {
            return try JSONDecoder().decode([PairedDevice].self, from: data)
        } catch {
            logger.error("Failed to decode paired devices: \(error)")
            return []
        }
    }

    func savePairedDevices(_ devices: [PairedDevice]) {
        do {
            let data = try JSONEncoder().encode(devices)
            save(key: pairedDevicesKey, data: data)
        } catch {
            logger.error("Failed to encode paired devices: \(error)")
        }
    }

    func addPairedDevice(_ device: PairedDevice) {
        var devices = loadPairedDevices()
        devices.removeAll { $0.id == device.id }  // Remove if already exists (re-pair)
        devices.append(device)
        savePairedDevices(devices)
    }

    func removePairedDevice(id: String) {
        var devices = loadPairedDevices()
        devices.removeAll { $0.id == id }
        savePairedDevices(devices)
    }

    // MARK: - Keychain Primitives

    private func save(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain add failed: \(addStatus)")
            }
        } else if status != errSecSuccess {
            logger.error("Keychain update failed: \(status)")
        }
    }

    private func load(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain load failed: \(status)")
            }
            return nil
        }
        return result as? Data
    }

    private func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
