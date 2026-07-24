// TailscaleAddress.swift
// Discovers this Mac's Tailscale address, so Beam on iPhone can reach Beacon from outside
// the local network (BEAM-19).
//
// Why this exists: Beacon's listener already accepts connections on every interface, the
// Tailscale utun included, so remote streaming needs no transport work at all. The only
// missing piece is *discovery* — Bonjour/mDNS does not traverse Tailscale, so the phone can
// never find the Mac that way. Beacon therefore tells the phone its own tailnet address
// during pairing and on every auth, and the phone falls back to it when Bonjour is silent.
//
// Detection is done by reading the interface list directly rather than shelling out to the
// `tailscale` CLI: no dependency on where Tailscale was installed (App Store build, brew,
// standalone pkg all differ), nothing to spawn, and it works in a sandboxed process.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.beam.beacon", category: "Tailscale")

enum TailscaleAddress {

    /// Tailscale hands out CGNAT-space addresses: 100.64.0.0/10 (100.64.x.x – 100.127.x.x).
    /// That range is reserved for carrier NAT and is not otherwise routable, so a local
    /// address inside it is a reliable tailnet signal.
    private static func isTailscaleIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return parts[1] >= 64 && parts[1] <= 127
    }

    /// This Mac's Tailscale IPv4 address, or nil when Tailscale isn't running/installed.
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidate: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var storage = sockaddr_in()
            memcpy(&storage, sa, Int(MemoryLayout<sockaddr_in>.size))
            var raw = storage.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let address = String(cString: buffer)

            if isTailscaleIPv4(address) {
                candidate = address
                break
            }
        }
        return candidate
    }

    /// Addresses to advertise to the iPhone, best-first. Empty when there's no tailnet.
    ///
    /// Only the raw IPv4 is reported. MagicDNS names are deliberately *not* included: they
    /// resolve only when the client's DNS is being handled by Tailscale, which is a setting
    /// users often turn off, and a name that resolves on the Mac but not the phone would
    /// produce a silent connection failure that looks like a Beam bug. The numeric address
    /// works whenever the tailnet is up, and it is refreshed on every auth so churn is fine.
    static func advertisedHosts() -> [String]? {
        guard let address = current() else {
            logger.debug("No Tailscale address found — remote fallback unavailable")
            return nil
        }
        logger.info("Advertising Tailscale address to paired clients")
        return [address]
    }
}
