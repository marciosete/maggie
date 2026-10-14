import Foundation

/// Where a device can reach this Mac: its Tailscale address or name first, since that
/// works away from home, then its addresses on the local network.
enum RemoteAddresses {
    struct Address: Equatable, Hashable {
        enum Kind {
            case tailscale
            case local
        }

        let kind: Kind
        let value: String
    }

    /// The Mac's IPv4 addresses, Tailscale's first.
    static func current() -> [Address] {
        var found: [Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            guard let kind = kind(of: bytes) else { continue }
            let value = bytes.map(String.init).joined(separator: ".")
            if !found.contains(where: { $0.value == value }) {
                found.append(Address(kind: kind, value: value))
            }
        }
        return found.filter { $0.kind == .tailscale } + found.filter { $0.kind == .local }
    }

    /// Tailscale's range is 100.64.0.0/10; the private ranges are the local network's.
    static func kind(of bytes: [UInt8]) -> Address.Kind? {
        guard bytes.count == 4 else { return nil }
        if bytes[0] == 100, (64...127).contains(bytes[1]) { return .tailscale }
        if bytes[0] == 10 { return .local }
        if bytes[0] == 172, (16...31).contains(bytes[1]) { return .local }
        if bytes[0] == 192, bytes[1] == 168 { return .local }
        return nil
    }

    /// The Mac's Tailscale DNS name, such as `macmini.tail1234.ts.net`, if Tailscale is
    /// installed and signed in. Runs its command line, so call it off the main thread.
    static func tailscaleName() -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return dnsName(fromStatus: data)
    }

    /// `Self.DNSName` from `tailscale status --json`, without its trailing dot.
    static func dnsName(fromStatus data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
