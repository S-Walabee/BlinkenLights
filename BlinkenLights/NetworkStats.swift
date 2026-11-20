import Foundation

/// Cumulative byte counters for kernel network connections to one server.
struct NetCounters {
    var bytesIn: UInt64
    var bytesOut: UInt64
}

/// Reads the kernel's file-sharing connections (SMB, NFS, AFP) from `nettop`.
///
/// Network file systems run in the kernel, so their traffic appears under
/// `kernel_task`. Bytes in are treated as reads, bytes out as writes.
enum NetworkStats {
    /// Remote ports used by kernel network file systems.
    static let fileSharingPorts: Set<Int> = [445, 139, 2049, 548]

    /// Returns remote IP address -> summed counters for all file-sharing connections.
    static func sample() -> [String: NetCounters] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-m", "tcp", "-n", "-L", "1", "-p", "kernel_task", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses lines like `tcp4 192.168.5.113:58065<->192.168.5.20:445,264861463416,88181734,`.
    static func parse(_ text: String) -> [String: NetCounters] {
        var result: [String: NetCounters] = [:]
        for line in text.split(separator: "\n") {
            guard let arrow = line.range(of: "<->") else { continue }
            let fields = line[arrow.upperBound...].split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let (host, port) = splitHostPort(String(fields[0])),
                  fileSharingPorts.contains(port),
                  let bytesIn = UInt64(fields[1]),
                  let bytesOut = UInt64(fields[2]) else { continue }
            var counters = result[host] ?? NetCounters(bytesIn: 0, bytesOut: 0)
            counters.bytesIn &+= bytesIn
            counters.bytesOut &+= bytesOut
            result[host] = counters
        }
        return result
    }

    /// IPv4 endpoints look like `a.b.c.d:port`; IPv6 endpoints like `addr%iface.port`.
    static func splitHostPort(_ endpoint: String) -> (String, Int)? {
        let isIPv4 = endpoint.filter { $0 == ":" }.count == 1
        guard let index = endpoint.lastIndex(of: isIPv4 ? ":" : "."),
              let port = Int(endpoint[endpoint.index(after: index)...]) else { return nil }
        var host = String(endpoint[..<index])
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        return (host, port)
    }
}

/// Resolves a network share's server name to IP addresses, including Bonjour
/// service names such as `My Mac._smb._tcp.local`.
@MainActor
final class ServerResolver: NSObject, NetServiceDelegate {
    private var resolved: [String: Set<String>] = [:]
    private var bonjour: [String: NetService] = [:]
    private var lookingUp: Set<String> = []

    /// Addresses known for a server name, or nil if not yet resolved.
    func addresses(for server: String) -> Set<String>? {
        if let known = resolved[server] { return known }
        startResolving(server)
        return nil
    }

    private func startResolving(_ server: String) {
        guard bonjour[server] == nil, !lookingUp.contains(server) else { return }
        // Bonjour service names: "<name>._<type>._tcp.<domain>"
        if let range = server.range(of: #"\._[A-Za-z0-9-]+\._tcp\."#, options: .regularExpression) {
            let name = String(server[..<range.lowerBound])
            let type = String(server[server.index(after: range.lowerBound)..<range.upperBound])
            var domain = String(server[range.upperBound...])
            if !domain.hasSuffix(".") { domain += "." }
            let service = NetService(domain: domain, type: type, name: name)
            service.delegate = self
            bonjour[server] = service
            service.resolve(withTimeout: 5)
            return
        }
        // Plain host name or IP address: resolve off the main thread.
        lookingUp.insert(server)
        Task.detached {
            let addresses = Self.lookup(host: server)
            await MainActor.run {
                self.lookingUp.remove(server)
                if !addresses.isEmpty { self.resolved[server] = addresses }
            }
        }
    }

    nonisolated private static func lookup(host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0 else { return [] }
        defer { freeaddrinfo(info) }
        var result = Set<String>()
        var cursor = info
        while let ai = cursor {
            if let address = numericHost(ai.pointee.ai_addr, ai.pointee.ai_addrlen) { result.insert(address) }
            cursor = ai.pointee.ai_next
        }
        return result
    }

    nonisolated static func numericHost(_ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> String? {
        guard let addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, len, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        var host = String(cString: buffer)
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        return host
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let addresses = Set((sender.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                return Self.numericHost(base.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count))
            }
        })
        MainActor.assumeIsolated {
            guard let server = bonjour.first(where: { $0.value === sender })?.key else { return }
            if !addresses.isEmpty { resolved[server, default: []].formUnion(addresses) }
        }
    }

    nonisolated func netServiceDidStop(_ sender: NetService) {
        MainActor.assumeIsolated {
            if let server = bonjour.first(where: { $0.value === sender })?.key { bonjour[server] = nil }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated {
            if let server = bonjour.first(where: { $0.value === sender })?.key { bonjour[server] = nil }
        }
    }
}
