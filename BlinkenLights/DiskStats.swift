import Foundation
import IOKit

/// Cumulative I/O counters for one block storage driver.
struct IOCounters: Equatable {
    var readOps: UInt64
    var writeOps: UInt64
}

/// Reads per-device I/O counters from IOKit.
///
/// macOS only keeps counters per physical (or disk-image) block device, so a
/// volume is mapped to the `IOBlockStorageDriver` beneath it. APFS volumes that
/// share a container therefore share activity.
final class DiskStats {
    /// BSD name (e.g. "disk3s1") -> registry entry ID of its IOBlockStorageDriver.
    private var driverCache: [String: UInt64] = [:]

    /// Returns the registry entry ID of the storage driver beneath a BSD device.
    func driverID(forBSDName bsdName: String) -> UInt64? {
        if let cached = driverCache[bsdName] { return cached }
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &id)
                IOObjectRelease(entry)
                driverCache[bsdName] = id
                return id
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, "IOService", &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }

    func forgetCache() {
        driverCache.removeAll()
    }

    /// Reads the current counters for a driver registry entry ID.
    func counters(forDriverID id: UInt64) -> IOCounters? {
        guard let matching = IORegistryEntryIDMatching(id) else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        let reads = (stats["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
        let writes = (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
        return IOCounters(readOps: reads, writeOps: writes)
    }
}
