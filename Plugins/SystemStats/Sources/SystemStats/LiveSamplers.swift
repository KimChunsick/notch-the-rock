import Darwin
import Foundation
import IOKit

extension Samplers {
    /// The samplers that read this Mac. Every call is a direct kernel or IOKit read; nothing is
    /// shelled out.
    @MainActor
    static func live() -> Samplers {
        Samplers(
            cpu: HostCPUSampler(),
            gpu: AcceleratorSampler(),
            memory: HostMemorySampler(),
            disk: BootDiskSampler(),
            network: InterfaceSampler(),
            sensors: SMCSensorSampler()
        )
    }
}

/// Per-core ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
final class HostCPUSampler: CPUSampler {
    private let host = mach_host_self()

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func coreTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(
                user: ticks(CPU_STATE_USER),
                system: ticks(CPU_STATE_SYSTEM),
                idle: ticks(CPU_STATE_IDLE),
                nice: ticks(CPU_STATE_NICE)
            )
        }
    }
}

/// Used memory from `host_statistics64(HOST_VM_INFO64)` with the host page size, and the pressure
/// level from the `kern.memorystatus_vm_pressure_level` sysctl.
final class HostMemorySampler: MemorySampler {
    private let host = mach_host_self()

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let pages = VMPages(
            anonymous: UInt64(stats.internal_page_count),
            purgeable: UInt64(stats.purgeable_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count)
        )
        return MemoryReading(
            used: pages.usedBytes(pageSize: UInt64(pageSize)),
            total: ProcessInfo.processInfo.physicalMemory,
            pressure: Self.pressure()
        )
    }

    private static func pressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(level: level)
    }
}

/// The highest "Device Utilization %" among the IOAccelerator services' `PerformanceStatistics`.
struct AcceleratorSampler: GPUSampler {
    func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var highest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let value = (statistics?["Device Utilization %"] as? NSNumber)?.doubleValue {
                highest = max(highest ?? 0, min(max(value, 0), 100))
            }
        }
        return highest
    }
}

/// Space from `statfs("/")` (what `df` reports) and byte counters from the `Statistics` of the
/// IOBlockStorageDriver under the boot volume. The driver is found once, by walking up the IOKit
/// service plane from the boot volume's BSD name (an APFS snapshot such as `disk3s1s1`) through its
/// container to the physical disk; disk images and other disks have drivers of their own and are
/// not counted.
final class BootDiskSampler: DiskSampler {
    private let driver: io_registry_entry_t
    /// BSD name of the physical disk the driver serves, e.g. `disk0`.
    let physicalDiskName: String?

    init() {
        (driver, physicalDiskName) = Self.findDriver(bsdName: Self.bootDevice())
    }

    deinit {
        if driver != 0 { IOObjectRelease(driver) }
    }

    func space() -> DiskSpace? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let blockSize = UInt64(info.f_bsize)
        return DiskSpace(total: UInt64(info.f_blocks) * blockSize, free: UInt64(info.f_bavail) * blockSize)
    }

    func counters() -> ByteCounters? {
        guard driver != 0,
              let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [String: Any],
              let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
              let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value
        else { return nil }
        return ByteCounters(inbound: read, outbound: written)
    }

    /// "disk3s1s1" for "/dev/disk3s1s1".
    private static func bootDevice() -> String? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let device = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : nil
    }

    private static func findDriver(bsdName: String?) -> (io_registry_entry_t, String?) {
        guard let bsdName else { return (0, nil) }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        var diskName: String?
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                return (entry, diskName)
            }
            if IOObjectConformsTo(entry, "IOMedia") != 0,
               let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                diskName = name
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = result == KERN_SUCCESS ? parent : 0
        }
        return (0, nil)
    }
}

/// 64-bit byte counters of every interface that is up, running and not a loopback, from the
/// `NET_RT_IFLIST2` routing sysctl (`if_msghdr2.ifm_data` is an `if_data64`, so counters past 4 GiB
/// do not wrap as the 32-bit `getifaddrs` counters do).
struct InterfaceSampler: NetworkSampler {
    func counters() -> [String: ByteCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: ByteCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length
                else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let flags = message.ifm_flags
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                      let name = Self.name(ofInterface: message.ifm_index)
                else { continue }
                result[name] = ByteCounters(inbound: message.ifm_data.ifi_ibytes, outbound: message.ifm_data.ifi_obytes)
            }
        }
        return result
    }

    private static func name(ofInterface index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
