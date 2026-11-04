import Foundation

/// The check the IPv6 echo's answer must pass before it is sent.
enum PublicIPv6 {
    /// The canonical text (RFC 5952: lowercase, longest zero run as `::`) of a global unicast IPv6
    /// address (2000::/3, the first three bits 001); nil for anything else: IPv4, IPv4-mapped,
    /// loopback, link-local, unique-local, multicast, a zone id or garbage.
    static func globalUnicast(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `inet_pton` reads a C string: an embedded NUL would cut it short.
        guard !trimmed.isEmpty, trimmed.utf8.count < Int(INET6_ADDRSTRLEN), !trimmed.utf8.contains(0) else {
            return nil
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, trimmed, &address) == 1 else { return nil }
        let first = withUnsafeBytes(of: &address) { $0[0] }
        guard first & 0xE0 == 0x20 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let canonical = buffer.withUnsafeMutableBufferPointer { out -> String? in
            guard let base = out.baseAddress, inet_ntop(AF_INET6, &address, base, socklen_t(out.count)) != nil
            else { return nil }
            return String(cString: base)
        }
        return canonical?.lowercased()
    }
}
