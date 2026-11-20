import AppKit
import Observation

/// What one volume's LEDs should show.
struct VolumeState: Identifiable, Equatable {
    let id: String          // mount point
    let name: String        // human-friendly volume name
    let isNetwork: Bool
    var reading = false
    var writing = false
}

/// A mounted, user-visible volume and how to measure its activity.
private struct MountedVolume: Equatable {
    let mountPoint: String
    let name: String
    let bsdName: String?    // local volumes
    let server: String?     // network volumes
}

/// Tracks mounted volumes and polls their read/write activity.
@Observable
@MainActor
final class VolumeMonitor {
    private(set) var volumes: [VolumeState] = []

    @ObservationIgnored private var mounted: [MountedVolume] = []
    @ObservationIgnored private let diskStats = DiskStats()
    @ObservationIgnored private let resolver = ServerResolver()
    @ObservationIgnored private var previousDisk: [UInt64: IOCounters] = [:]
    @ObservationIgnored private var previousNet: [String: NetCounters] = [:]
    @ObservationIgnored private var netActivity: [String: (read: Bool, write: Bool)] = [:]
    @ObservationIgnored private var netSampleInFlight = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticksSinceRescan = 0
    @ObservationIgnored private var rootName: String?

    /// Bytes per sample a network connection must move to count as activity
    /// (filters out SMB keep-alives and similar chatter).
    private let netThreshold: UInt64 = 2048

    func start(interval: Double) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            }
        }
        rescan()
        setInterval(interval)
    }

    func setInterval(_ interval: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)  // keep blinking while the menu is open
        self.timer = timer
    }

    // MARK: Volume discovery

    /// Re-reads the mount table. Uses MNT_NOWAIT so an unresponsive network
    /// server can never block the UI.
    func rescan() {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&buffer, MNT_NOWAIT))
        guard count > 0, let buffer else { return }

        var found: [MountedVolume] = []
        for i in 0..<count {
            var fs = buffer[i]
            let mountPoint = cString(&fs.f_mntonname)
            let source = cString(&fs.f_mntfromname)
            let flags = Int32(bitPattern: fs.f_flags)
            guard flags & MNT_DONTBROWSE == 0,
                  mountPoint == "/" || mountPoint.hasPrefix("/Volumes/") else { continue }

            if flags & MNT_LOCAL != 0 {
                guard source.hasPrefix("/dev/") else { continue }
                found.append(MountedVolume(mountPoint: mountPoint,
                                           name: displayName(for: mountPoint),
                                           bsdName: String(source.dropFirst(5)),
                                           server: nil))
            } else if let server = Self.serverName(fromMountSource: source) {
                found.append(MountedVolume(mountPoint: mountPoint,
                                           name: displayName(for: mountPoint),
                                           bsdName: nil,
                                           server: server))
            }
        }

        // Boot volume first, then local volumes, then network shares; alphabetical within each.
        found.sort { a, b in
            func rank(_ v: MountedVolume) -> Int { v.mountPoint == "/" ? 0 : (v.server == nil ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        guard found != mounted else { return }
        mounted = found
        diskStats.forgetCache()
        let old = Dictionary(volumes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        volumes = found.map { v in
            var state = VolumeState(id: v.mountPoint, name: v.name, isNetwork: v.server != nil)
            if let previous = old[v.mountPoint] {
                state.reading = previous.reading
                state.writing = previous.writing
            }
            return state
        }
    }

    private func displayName(for mountPoint: String) -> String {
        if mountPoint == "/" {
            // The boot volume's mount point is "/", so ask for its real name (local, never blocks).
            if rootName == nil {
                rootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?
                    .volumeLocalizedName ?? "Macintosh HD"
            }
            return rootName!
        }
        return (mountPoint as NSString).lastPathComponent
    }

    private func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    /// Extracts the server from `//user@server/share` (SMB/AFP) or `server:/path` (NFS).
    static func serverName(fromMountSource source: String) -> String? {
        if source.hasPrefix("//") {
            var authority = source.dropFirst(2)
            if let slash = authority.firstIndex(of: "/") { authority = authority[..<slash] }
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            if let colon = authority.lastIndex(of: ":"), !authority.contains("[") { authority = authority[..<colon] }
            let server = String(authority).removingPercentEncoding ?? String(authority)
            return server.isEmpty ? nil : server
        }
        if let range = source.range(of: ":/") {
            return String(source[..<range.lowerBound])
        }
        return nil
    }

    // MARK: Polling

    private func tick() {
        ticksSinceRescan += 1
        if ticksSinceRescan * Int(max(AppSettings.shared.updateInterval, 0.1) * 1000) >= 5000 {
            ticksSinceRescan = 0
            rescan()   // safety net in case a mount/unmount notification is missed
        }

        // Local disks: one IOKit read per storage driver.
        var diskActivity: [UInt64: (read: Bool, write: Bool)] = [:]
        var current: [UInt64: IOCounters] = [:]
        for volume in mounted {
            guard let bsd = volume.bsdName, let driver = diskStats.driverID(forBSDName: bsd) else { continue }
            if current[driver] != nil { continue }
            guard let counters = diskStats.counters(forDriverID: driver) else { continue }
            current[driver] = counters
            if let previous = previousDisk[driver] {
                diskActivity[driver] = (counters.readOps > previous.readOps, counters.writeOps > previous.writeOps)
            }
        }
        previousDisk = current

        // Network shares: sample nettop off the main thread.
        if mounted.contains(where: { $0.server != nil }) {
            if !netSampleInFlight {
                netSampleInFlight = true
                Task.detached(priority: .utility) {
                    let sample = NetworkStats.sample()
                    await MainActor.run { self.applyNetworkSample(sample) }
                }
            }
        } else {
            netActivity = [:]
            previousNet = [:]
        }

        var updated = volumes
        for (index, volume) in mounted.enumerated() where index < updated.count {
            if let bsd = volume.bsdName {
                let driver = diskStats.driverID(forBSDName: bsd)
                let activity = driver.flatMap { diskActivity[$0] } ?? (false, false)
                updated[index].reading = activity.read
                updated[index].writing = activity.write
            } else if let server = volume.server {
                let activity = networkActivity(for: server)
                updated[index].reading = activity.read
                updated[index].writing = activity.write
            }
        }
        if updated != volumes { volumes = updated }
    }

    private func applyNetworkSample(_ sample: [String: NetCounters]) {
        netSampleInFlight = false
        var activity: [String: (read: Bool, write: Bool)] = [:]
        for (host, counters) in sample {
            guard let previous = previousNet[host] else { continue }
            let inDelta = counters.bytesIn &- previous.bytesIn
            let outDelta = counters.bytesOut &- previous.bytesOut
            // Ignore counter resets (reconnects) and keep the small request/ack
            // traffic that accompanies a big transfer from lighting the other LED.
            let validIn = counters.bytesIn >= previous.bytesIn ? inDelta : 0
            let validOut = counters.bytesOut >= previous.bytesOut ? outDelta : 0
            // Directory listings and other metadata send many small requests, so
            // only call it a write when more goes out than comes back.
            activity[host] = (validIn >= netThreshold && validIn >= validOut / 32,
                              validOut >= netThreshold && validOut > validIn)
        }
        previousNet = sample
        netActivity = activity
    }

    private func networkActivity(for server: String) -> (read: Bool, write: Bool) {
        let hosts: Set<String>
        if let addresses = resolver.addresses(for: server) {
            hosts = addresses
        } else if previousNet.count == 1, let only = previousNet.keys.first {
            hosts = [only]   // not resolved yet, but there is only one file server connected
        } else {
            return (false, false)
        }
        var result = (read: false, write: false)
        for host in hosts {
            if let a = netActivity[host] {
                result.read = result.read || a.read
                result.write = result.write || a.write
            }
        }
        return result
    }
}
