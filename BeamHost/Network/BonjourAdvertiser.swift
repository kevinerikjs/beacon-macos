// BonjourAdvertiser.swift
// Advertises the Beam stream server on the local network via Bonjour.
// iOS devices browse for "_beam._tcp" to discover this Mac.

import Network
import OSLog

private let logger = Logger(subsystem: "com.beam.host", category: "Bonjour")

/// The Bonjour service type used by both macOS and iOS.
let kBeamServiceType = "_beam._tcp"

final class BonjourAdvertiser {

    private var listener: NWListener?
    private let port: NWEndpoint.Port
    private let deviceName: String

    /// `port` should match the port the StreamServer is listening on.
    init(port: UInt16, deviceName: String = Host.current().localizedName ?? "Mac") {
        self.port = NWEndpoint.Port(rawValue: port) ?? 7979
        self.deviceName = deviceName
    }

    // MARK: - Start / Stop

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            // Create listener specifically for Bonjour advertisement
            // (The actual connection handling is in StreamServer - this just announces)
            listener = try NWListener(using: parameters, on: port)
            listener?.service = NWListener.Service(
                name: deviceName,
                type: kBeamServiceType,
                domain: "local."
            )

            listener?.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add(let endpoint):
                    logger.info("Bonjour service registered: \(String(describing: endpoint))")
                case .remove(let endpoint):
                    logger.info("Bonjour service removed: \(String(describing: endpoint))")
                @unknown default:
                    break
                }
            }

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    logger.info("Bonjour advertiser ready on port \(self?.port.rawValue ?? 0)")
                case .failed(let error):
                    logger.error("Bonjour advertiser failed: \(error)")
                    self?.scheduleRestart()
                case .cancelled:
                    logger.info("Bonjour advertiser cancelled")
                default:
                    break
                }
            }

            // Note: We intentionally ignore new incoming connections here -
            // StreamServer handles connection acceptance on its own listener.
            listener?.newConnectionHandler = { connection in
                // Let connection go to StreamServer's listener instead
                connection.cancel()
            }

            listener?.start(queue: .global(qos: .utility))
            logger.info("BonjourAdvertiser starting for service '\(self.deviceName)' on port \(self.port.rawValue)")

        } catch {
            logger.error("Failed to create Bonjour listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        logger.info("BonjourAdvertiser stopped")
    }

    private func scheduleRestart() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.stop()
            self.start()
        }
    }
}
