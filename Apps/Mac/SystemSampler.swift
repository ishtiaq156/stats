import ActivityCore
import AppKit
import Darwin
import Foundation
import IOKit.ps

final class SystemSampler {
    private var previousCPU: (used: UInt64, total: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, date: Date)?

    // Hardware identity and icon are stable for the lifetime of the companion process.
    // Keep the expensive system_profiler invocation and PNG rendering to one fetch.
    private static let cachedAbout = buildAbout()

    static func about() -> MacAboutInfo { cachedAbout }

    private static func buildAbout() -> MacAboutInfo {
        let hardware = systemProfile("SPHardwareDataType")
        let model = hardware["machine_name"] ?? "Mac"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let release = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let macOS = version.majorVersion == 27 ? "Golden Gate \(release)" :
            version.majorVersion == 26 ? "Tahoe \(release)" : release
        let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName
        return MacAboutInfo(modelName: model, chip: hardware["chip_type"],
                            memory: hardware["physical_memory"], startupDisk: disk,
                            serialNumber: hardware["serial_number"], macOS: macOS,
                            imagePNG: systemImage(for: model))
    }

    private static func systemProfile(_ kind: String) -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", kind]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json[kind] as? [[String: Any]], let entry = entries.first else { return [:] }
        return entry.compactMapValues { $0 as? String }
    }

    private static func systemImage(for model: String) -> Data? {
        let root = "/System/Library/CoreServices/CoreTypes.bundle/Contents"
        let path: String
        if model.localizedCaseInsensitiveContains("Mac mini") {
            path = "Library/CoreTypes-0021.bundle/Contents/Resources/com.apple.macmini-2024.icns"
        } else if model.localizedCaseInsensitiveContains("Mac Studio") {
            path = "Resources/com.apple.macstudio.icns"
        } else if model.localizedCaseInsensitiveContains("MacBook Pro") {
            path = "Library/CoreTypes-0013.bundle/Contents/Resources/com.apple.macbookpro-14-late-2023-2-space-black.icns"
        } else if model.localizedCaseInsensitiveContains("MacBook Air") {
            path = "Library/CoreTypes-0024.bundle/Contents/Resources/com.apple.macbookair-13-2025-sky-blue.icns"
        } else if model.localizedCaseInsensitiveContains("iMac") {
            path = "Library/CoreTypes-0020.bundle/Contents/Resources/com.apple.imac-2024-blue.icns"
        } else if model.localizedCaseInsensitiveContains("Mac Pro") {
            path = "Resources/com.apple.macpro-2019.icns"
        } else {
            return nil
        }
        guard let source = NSImage(contentsOfFile: "\(root)/\(path)") else { return nil }
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func sample() -> MetricSnapshot {
        let date = Date()
        let cpu = cpuUsage()
        let memory = memoryUsage()
        let disk = diskUsage()
        let network = networkRates(at: date)
        let battery = batteryStatus()

        return MetricSnapshot(
            machineName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            timestamp: date,
            cpuFraction: cpu,
            memoryUsedBytes: memory?.used,
            memoryTotalBytes: memory?.total,
            diskFreeBytes: disk?.free,
            diskTotalBytes: disk?.total,
            networkReceivedBytesPerSecond: network?.received,
            networkSentBytesPerSecond: network?.sent,
            batteryFraction: battery?.fraction,
            isCharging: battery?.charging
        )
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let used = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.2)
        let total = used + UInt64(info.cpu_ticks.3)
        defer { previousCPU = (used, total) }
        guard let previousCPU, total > previousCPU.total, used >= previousCPU.used else { return nil }
        return min(1, Double(used - previousCPU.used) / Double(total - previousCPU.total))
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let used = (UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * page
        return (min(used, ProcessInfo.processInfo.physicalMemory), ProcessInfo.processInfo.physicalMemory)
    }

    private func diskUsage() -> (free: UInt64, total: UInt64)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]), let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (UInt64(max(0, free)), UInt64(max(0, total)))
    }

    private func networkRates(at date: Date) -> (received: Double, sent: Double)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor = head
        while let item = cursor {
            let address = item.pointee.ifa_addr
            if address?.pointee.sa_family == UInt8(AF_LINK),
               item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               let data = item.pointee.ifa_data {
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(counters.ifi_ibytes)
                sent += UInt64(counters.ifi_obytes)
            }
            cursor = item.pointee.ifa_next
        }
        defer { previousNetwork = (received, sent, date) }
        guard let previousNetwork, received >= previousNetwork.received,
              sent >= previousNetwork.sent else { return nil }
        let elapsed = date.timeIntervalSince(previousNetwork.date)
        guard elapsed > 0 else { return nil }
        return (Double(received - previousNetwork.received) / elapsed,
                Double(sent - previousNetwork.sent) / elapsed)
    }

    private func batteryStatus() -> (fraction: Double, charging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return (min(1, Double(current) / Double(maximum)), charging)
        }
        return nil
    }
}
