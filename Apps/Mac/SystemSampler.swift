import ActivityCore
import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

@MainActor
final class SystemSampler {
    private struct CoreTopology {
        let physical: Int?
        let logical: Int?
        let types: [String]?
        let efficiency: Int?
        let performance: Int?
        let supers: Int?
    }

    private static let topology = readCoreTopology()
    private var previousCPUTicks: [UInt32]?
    private var cachedProcesses: [CPUProcess]?
    private var processesFetching = false
    private var lastProcessesFetch: Date = .distantPast
    private var cachedRAMProcesses: [RAMProcess]?
    private var ramProcessesFetching = false
    private var lastRAMProcessesFetch: Date = .distantPast
    private var cachedHardware: CPUHardwareReadings?
    private var hardwareFetching = false
    private var lastHardwareFetch: Date = .distantPast
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
        let cpu = cpuUsage(at: date)
        refreshRAMProcessesIfNeeded(at: date)
        let memory = memoryUsage()
        let disk = diskUsage()
        let network = networkRates(at: date)
        let battery = batteryStatus()

        return MetricSnapshot(
            machineName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            timestamp: date,
            cpuFraction: cpu.usage,
            memoryUsedBytes: memory?.used,
            memoryTotalBytes: memory?.total,
            diskFreeBytes: disk?.free,
            diskTotalBytes: disk?.total,
            networkReceivedBytesPerSecond: network?.received,
            networkSentBytesPerSecond: network?.sent,
            batteryFraction: battery?.fraction,
            isCharging: battery?.charging,
            cpuDetails: cpu.details,
            ramDetails: memory?.details
        )
    }

    private func cpuUsage(at date: Date) -> (usage: Double?, details: CPUDetails) {
        refreshProcessesIfNeeded(at: date)
        refreshHardwareIfNeeded(at: date)
        var cpuCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var busy: Double?
        var user: Double?
        var system: Double?
        var idle: Double?
        var perCore: [Double]?

        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &cpuInfo, &infoCount)
        if status == KERN_SUCCESS, let cpuInfo {
            defer {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo),
                              vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
            }
            let current = (0..<Int(infoCount)).map { UInt32(bitPattern: cpuInfo[$0]) }
            let coreCount = min(Int(cpuCount), current.count / Int(CPU_STATE_MAX))
            if let previous = previousCPUTicks, previous.count == current.count, coreCount > 0 {
                var userTicks: UInt64 = 0
                var systemTicks: UInt64 = 0
                var idleTicks: UInt64 = 0
                var niceTicks: UInt64 = 0
                var individual: [Double] = []
                for i in 0..<coreCount {
                    let offset = i * Int(CPU_STATE_MAX)
                    let u = UInt64(current[offset + Int(CPU_STATE_USER)] &- previous[offset + Int(CPU_STATE_USER)])
                    let s = UInt64(current[offset + Int(CPU_STATE_SYSTEM)] &- previous[offset + Int(CPU_STATE_SYSTEM)])
                    let n = UInt64(current[offset + Int(CPU_STATE_NICE)] &- previous[offset + Int(CPU_STATE_NICE)])
                    let d = UInt64(current[offset + Int(CPU_STATE_IDLE)] &- previous[offset + Int(CPU_STATE_IDLE)])
                    let total = u + s + n + d
                    individual.append(total > 0 ? Double(u + s + n) / Double(total) : 0)
                    userTicks += u
                    systemTicks += s
                    niceTicks += n
                    idleTicks += d
                }
                let total = userTicks + systemTicks + niceTicks + idleTicks
                if total > 0 {
                    let ticks = Double(total)
                    user = Double(userTicks + niceTicks) / ticks
                    system = Double(systemTicks) / ticks
                    idle = Double(idleTicks) / ticks
                    busy = (user ?? 0) + (system ?? 0)
                    perCore = individual
                }
            }
            previousCPUTicks = current
        }

        var averages = [Double](repeating: 0, count: 3)
        let averageCount = averages.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, Int32(buffer.count))
        }
        let topology = Self.topology
        let details = CPUDetails(
            userFraction: user, systemFraction: system, idleFraction: idle,
            perCoreFractions: perCore, coreTypes: topology.types,
            physicalCores: topology.physical, logicalCores: topology.logical,
            efficiencyCores: topology.efficiency, performanceCores: topology.performance,
            superCores: topology.supers,
            loadAverages: averageCount == 3 ? averages : nil,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            temperatureCelsius: cachedHardware?.temperatureCelsius,
            frequencyMHz: cachedHardware?.frequencyMHz,
            efficiencyFrequencyMHz: cachedHardware?.efficiencyFrequencyMHz,
            performanceFrequencyMHz: cachedHardware?.performanceFrequencyMHz,
            superFrequencyMHz: cachedHardware?.superFrequencyMHz,
            topProcesses: cachedProcesses
        )
        return (busy, details)
    }

    private static func sysctlNumber(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    private static func sysctlText(_ key: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // Interpret AppleARMPE cluster types using the device's reported CPU topology.
    // On M5/M6, P=Super, M=Performance and E=Efficiency; older Macs use P=Performance.
    private static func readCoreTopology() -> CoreTopology {
        let physical = sysctlNumber("hw.physicalcpu")
        let logical = sysctlNumber("hw.logicalcpu")
        let hasSuperCluster = (0..<4).contains { sysctlText("hw.perflevel\($0).name") == "Super" }
        var mapped: [Int: String] = [:]
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var children: io_iterator_t = 0
                guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(children) }
                while case let child = IOIteratorNext(children), child != 0 {
                    defer { IOObjectRelease(child) }
                    var nameBuffer = [CChar](repeating: 0, count: 128)
                    let readName = nameBuffer.withUnsafeMutableBufferPointer {
                        IORegistryEntryGetName(child, $0.baseAddress!)
                    }
                    guard readName == KERN_SUCCESS else { continue }
                    let name = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    guard name.hasPrefix("cpu"), let index = Int(name.dropFirst(3)), index >= 0 else { continue }
                    guard let raw = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString,
                                                                     kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { continue }
                    let cluster = String(decoding: raw, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    switch cluster {
                    case "E": mapped[index] = "efficiency"
                    case "M": mapped[index] = "performance"
                    case "P": mapped[index] = hasSuperCluster ? "super" : "performance"
                    default: break
                    }
                }
            }
        }

        // Individual core classifications are only used if IORegistry identifies every core.
        let types: [String]? = {
            guard let logical, logical > 0, (0..<logical).allSatisfy({ mapped[$0] != nil }) else { return nil }
            return (0..<logical).map { mapped[$0]! }
        }()
        var counts: [String: Int] = [:]
        for index in 0..<4 {
            guard let name = sysctlText("hw.perflevel\(index).name"),
                  let count = sysctlNumber("hw.perflevel\(index).logicalcpu") else { continue }
            counts[name.lowercased(), default: 0] += count
        }
        if let types {
            counts["efficiency"] = types.filter { $0 == "efficiency" }.count
            counts["performance"] = types.filter { $0 == "performance" }.count
            counts["super"] = types.filter { $0 == "super" }.count
        }
        return CoreTopology(physical: physical, logical: logical, types: types,
                            efficiency: counts["efficiency"], performance: counts["performance"],
                            supers: counts["super"])
    }

    private func refreshProcessesIfNeeded(at date: Date) {
        guard !processesFetching, date.timeIntervalSince(lastProcessesFetch) >= 4 else { return }
        lastProcessesFetch = date
        processesFetching = true
        Task.detached(priority: .utility) { [weak self] in
            let processes = Self.readTopProcesses()
            await self?.receivedProcesses(processes)
        }
    }

    private func receivedProcesses(_ processes: [CPUProcess]) {
        cachedProcesses = processes
        processesFetching = false
    }

    // IOReport needs a real sampling interval, and SMC reads can briefly block.
    // Keep both off the two-second main-actor snapshot timer.
    private func refreshHardwareIfNeeded(at date: Date) {
        guard !hardwareFetching, date.timeIntervalSince(lastHardwareFetch) >= 4 else { return }
        hardwareFetching = true
        lastHardwareFetch = date
        Task.detached(priority: .utility) { [weak self] in
            let reading = CPUHardwareSensorReader.shared.read()
            await self?.receivedHardware(reading)
        }
    }

    private func receivedHardware(_ reading: CPUHardwareReadings) {
        cachedHardware = reading
        hardwareFetching = false
    }

    nonisolated private static func readTopProcesses() -> [CPUProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid,pcpu,comm", "-r"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").dropFirst().prefix(8).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int(fields[0]),
                  let percentage = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  percentage.isFinite, percentage >= 0 else { return nil }
            let command = String(fields[2])
            let name = (command as NSString).lastPathComponent
            return CPUProcess(pid: pid, name: name, usagePercent: percentage)
        })
    }

    // Rank RAM processes using macOS `top`'s MEM metric.
    // The command is relatively expensive; only refresh it on a detached task.
    private func refreshRAMProcessesIfNeeded(at date: Date) {
        guard !ramProcessesFetching, date.timeIntervalSince(lastRAMProcessesFetch) >= 4 else { return }
        lastRAMProcessesFetch = date
        ramProcessesFetching = true
        Task.detached(priority: .utility) { [weak self] in
            let processes = Self.readTopRAMProcesses()
            await self?.receivedRAMProcesses(processes)
        }
    }

    private func receivedRAMProcesses(_ processes: [RAMProcess]?) {
        cachedRAMProcesses = processes
        ramProcessesFetching = false
    }

    nonisolated private static func readTopRAMProcesses() -> [RAMProcess]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "1", "-o", "mem", "-n", "8", "-stats", "pid,command,mem"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        let processes = text.split(separator: "\n").compactMap { line -> RAMProcess? in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 3,
                  let pid = Int(columns[0].trimmingCharacters(in: CharacterSet(charactersIn: "*"))),
                  let memoryText = columns.last,
                  let bytes = parseTopMemory(memoryText) else { return nil }
            let command = columns.dropFirst().dropLast().joined(separator: " ")
            let appName = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
            return RAMProcess(pid: pid, name: appName ?? command, residentBytes: bytes)
        }
        guard !processes.isEmpty else { return nil }
        return Array(processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(8))
    }

    nonisolated private static func parseTopMemory(_ raw: Substring) -> UInt64? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = text.last else { return nil }
        let multiplier: Double
        let magnitude: Substring
        switch unit {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_048_576
        case "G": multiplier = 1_073_741_824
        case "T": multiplier = 1_099_511_627_776
        default:
            guard let bytes = UInt64(text) else { return nil }
            return bytes
        }
        magnitude = text.dropLast()
        guard let number = Double(magnitude), number.isFinite, number >= 0 else { return nil }
        let bytes = number * multiplier
        guard bytes.isFinite, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes)
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64, details: RAMDetails)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let total = ProcessInfo.processInfo.physicalMemory
        let active = UInt64(info.active_count) * page
        let inactive = UInt64(info.inactive_count) * page
        let speculative = UInt64(info.speculative_count) * page
        let wired = UInt64(info.wire_count) * page
        let compressed = UInt64(info.compressor_page_count) * page
        let cache = (UInt64(info.purgeable_count) + UInt64(info.external_page_count)) * page

        // Exclude purgeable and file-backed external pages from accounted memory.
        let accounted = active + inactive + speculative + wired + compressed
        let usedFromPages = accounted >= cache ? accounted - cache : 0
        // Inconsistent kernel counters must not produce a negative App segment
        // or a breakdown that exceeds the physical used/total figures.
        let used = min(total, max(usedFromPages, wired + compressed))
        let composedWired = min(wired, used)
        let composedCompressed = min(compressed, used - composedWired)
        let app = used - composedWired - composedCompressed

        var rawPressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressure: String? = {
            guard sysctlbyname("kern.memorystatus_vm_pressure_level", &rawPressure,
                               &pressureSize, nil, 0) == 0 else { return nil }
            switch rawPressure {
            case 1: return "normal"
            case 2: return "warning"
            case 4: return "critical"
            default: return nil
            }
        }()

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let details = RAMDetails(
            appBytes: app, wiredBytes: composedWired, compressedBytes: composedCompressed,
            freeBytes: total - used, cacheBytes: cache,
            activeBytes: active, inactiveBytes: inactive,
            swapTotalBytes: hasSwap ? swap.xsu_total : nil,
            swapUsedBytes: hasSwap ? swap.xsu_used : nil,
            swapFreeBytes: hasSwap ? swap.xsu_avail : nil,
            pressureLevel: pressure,
            swapIns: UInt64(info.swapins), swapOuts: UInt64(info.swapouts),
            topProcesses: cachedRAMProcesses
        )
        return (used, total, details)
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

private struct CPUHardwareReadings: Sendable {
    let temperatureCelsius: Double?
    let frequencyMHz: Double?
    let efficiencyFrequencyMHz: Double?
    let performanceFrequencyMHz: Double?
    let superFrequencyMHz: Double?
}

// Each read is scheduled once at a time by SystemSampler on a background task.
// The SMC connection and IOReport subscription remain open for the process lifetime.
private final class CPUHardwareSensorReader: @unchecked Sendable {
    static let shared = CPUHardwareSensorReader()

    private let smc = CPUAppleSMC()
    private let frequency = CPUIOReport()

    func read() -> CPUHardwareReadings {
        let temperature = smc?.readTemperature()
        let clocks = frequency?.readFrequency()
        return CPUHardwareReadings(
            temperatureCelsius: temperature,
            frequencyMHz: clocks?.overall,
            efficiencyFrequencyMHz: clocks?.efficiency,
            performanceFrequencyMHz: clocks?.performance,
            superFrequencyMHz: clocks?.superCore
        )
    }
}

// Read-only AppleSMC access works without the privileged fan-control helper.
// SMC key-info and read-byte commands use the IOKit SMC ABI.
private final class CPUAppleSMC {
    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    private struct Limits {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }
    private struct KeyInfo {
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt8 = 0
    }
    private typealias SensorBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    private struct KeyData {
        var key: UInt32 = 0
        var version = Version()
        var limits = Limits()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SensorBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private var connection: io_connect_t = 0
    // Validated on Mac18,5 (M6), macOS 27.0.1: Te* and Tp* keys respond
    // with changing, plausible die temperatures. Never average GPU Tg* keys.
    private let m6Keys = [
        "Te07", "Te08", "Te09", "Te0c", "Te0e", "Te0f", "Te0g", "Te0h", "Te0i",
        "Tp05", "Tp07", "Tp09", "Tp0A", "Tp0E", "Tp0G", "Tp0I", "Tp0L",
        "Tp0b", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0o", "Tp0r",
        "Tp0t", "Tp0u", "Tp0w", "Tp0x", "Tp0y", "Tp0z"
    ]

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func readTemperature() -> Double? {
        // Probe only chip-temperature candidates, not arbitrary SMC readings.
        // Known older Intel keys are supported; unknown chips gracefully return nil.
        let model = Self.hardwareModel()
        let keys = model.hasPrefix("Mac18,") ? m6Keys :
            ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"]
        let temperatures = keys.compactMap { key -> Double? in
            guard let value = read(key), value.isFinite, (10...120).contains(value) else { return nil }
            return value
        }
        guard !temperatures.isEmpty else { return nil }
        return temperatures.reduce(0, +) / Double(temperatures.count)
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, (1...128).contains(size) else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func invoke(_ request: inout KeyData) -> KeyData? {
        var reply = KeyData()
        var replySize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &request,
                                               MemoryLayout<KeyData>.stride, &reply, &replySize)
        guard result == KERN_SUCCESS, reply.result == 0,
              replySize >= MemoryLayout<KeyData>.size else { return nil }
        return reply
    }

    private func read(_ name: String) -> Double? {
        guard name.utf8.count == 4 else { return nil }
        let code = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var infoRequest = KeyData()
        infoRequest.key = code
        infoRequest.command = 9
        guard let info = invoke(&infoRequest)?.keyInfo, (1...32).contains(info.size) else { return nil }

        var valueRequest = KeyData()
        valueRequest.key = code
        valueRequest.command = 5
        valueRequest.keyInfo.size = info.size
        guard let value = invoke(&valueRequest) else { return nil }
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0) }
        let typeBytes = [
            UInt8((info.type >> 24) & 0xff), UInt8((info.type >> 16) & 0xff),
            UInt8((info.type >> 8) & 0xff), UInt8(info.type & 0xff)
        ]
        switch String(decoding: typeBytes, as: UTF8.self) {
        case "flt " where info.size >= 4:
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "sp78" where info.size >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 256
        case "sp87" where info.size >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 128
        default:
            return nil
        }
    }
}

// Private IOReport provides measured CPU power-state residencies, rather than
// fixed/base clocks. All symbols and channels are optional because macOS may
// change or restrict this interface. The subscription is initialized only once.
private final class CPUIOReport {
    private typealias ChannelFunction = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias SubscriptionFunction = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias SampleFunction = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFunction = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelNameFunction = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCountFunction = @convention(c) (CFDictionary) -> Int32
    private typealias ResidencyFunction = @convention(c) (CFDictionary, Int32) -> Int64

    struct Reading {
        let overall: Double?
        let efficiency: Double?
        let performance: Double?
        let superCore: Double?
    }

    private let library: UnsafeMutableRawPointer
    private let channels: CFMutableDictionary
    private let subscription: UnsafeMutableRawPointer
    private let samples: SampleFunction
    private let delta: DeltaFunction
    private let channelName: ChannelNameFunction
    private let stateCount: StateCountFunction
    private let residency: ResidencyFunction
    private let efficiencyStates: [Double]
    private let middleStates: [Double]
    private let highStates: [Double]

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let copy: ChannelFunction = symbol("IOReportCopyChannelsInGroup", ChannelFunction.self),
              let subscribe: SubscriptionFunction = symbol("IOReportCreateSubscription", SubscriptionFunction.self),
              let sample: SampleFunction = symbol("IOReportCreateSamples", SampleFunction.self),
              let difference: DeltaFunction = symbol("IOReportCreateSamplesDelta", DeltaFunction.self),
              let getName: ChannelNameFunction = symbol("IOReportChannelGetChannelName", ChannelNameFunction.self),
              let getCount: StateCountFunction = symbol("IOReportStateGetCount", StateCountFunction.self),
              let getResidency: ResidencyFunction = symbol("IOReportStateGetResidency", ResidencyFunction.self),
              let raw = copy("CPU Stats" as CFString, "CPU Core Performance States" as CFString,
                             0, 0, 0)?.takeRetainedValue(),
              let selected = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, raw) else {
            dlclose(handle)
            return nil
        }
        let e = Self.frequencyStates(for: "voltage-states1-sram") ?? []
        let upper = Self.frequencyStates(for: "voltage-states5-sram") ?? []
        let middle = Self.frequencyStates(for: "voltage-states22-sram") ?? upper
        guard !e.isEmpty || !middle.isEmpty || !upper.isEmpty else {
            dlclose(handle)
            return nil
        }
        var dictionary: Unmanaged<CFMutableDictionary>?
        guard let activeSubscription = subscribe(nil, selected, &dictionary, 0, nil) else {
            dictionary?.release()
            dlclose(handle)
            return nil
        }
        dictionary?.release()
        library = handle
        channels = selected
        subscription = activeSubscription
        samples = sample
        delta = difference
        channelName = getName
        stateCount = getCount
        residency = getResidency
        efficiencyStates = e
        middleStates = middle
        highStates = upper
    }

    func readFrequency() -> Reading? {
        guard let before = samples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        Thread.sleep(forTimeInterval: 0.4)
        guard let after = samples(subscription, channels, nil)?.takeRetainedValue(),
              let difference = delta(before, after, nil)?.takeRetainedValue(),
              let contents = difference as? [String: Any],
              let items = contents["IOReportChannels"] as? NSArray else { return nil }

        // Calculate the active-state clock for each logical core, then average
        // across the cores of each cluster and across all observed cores.
        // Weighting raw residency ticks across cores overrepresents busy cores.
        var frequencySum = [Double](repeating: 0, count: 3)
        var detected = [Int](repeating: 0, count: 3)
        let channelsList = items as CFArray
        for i in 0..<CFArrayGetCount(channelsList) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(channelsList, i), to: CFDictionary.self)
            guard let label = channelName(item)?.takeUnretainedValue() as String? else { continue }
            let group: Int
            let states: [Double]
            if label.contains("_ECPU") {
                group = 0
                states = efficiencyStates
            } else if label.contains("_MCPU") {
                group = 1
                states = middleStates
            } else if label.contains("_PCPU") {
                group = 2
                states = highStates
            } else {
                continue
            }
            guard !states.isEmpty, stateCount(item) == states.count + 1,
                  residency(item, 0) >= 0 else { continue }
            // State 0 is IDLE. Remaining state indices match the PMGR voltage
            // table from low to high MHz; weight each by this core's active ticks.
            var activeTicks = 0.0
            var weightedTicks = 0.0
            for index in states.indices {
                let ticks = residency(item, Int32(index + 1))
                guard ticks > 0 else { continue }
                activeTicks += Double(ticks)
                weightedTicks += Double(ticks) * states[index]
            }
            // Use the lowest supported clock when a core is fully idle.
            let coreFrequency = activeTicks > 0
                ? max(states[0], weightedTicks / activeTicks)
                : states[0]
            frequencySum[group] += coreFrequency
            detected[group] += 1
        }
        func frequency(_ group: Int) -> Double? {
            guard detected[group] > 0 else { return nil }
            return frequencySum[group] / Double(detected[group])
        }
        // M5/M6 expose a middle MCPU and super PCPU; earlier chips expose
        // just ECPU + PCPU, where PCPU denotes regular performance cores.
        let middleExists = detected[1] > 0
        let sampledCoreCount = detected.reduce(0, +)
        return Reading(
            overall: sampledCoreCount > 0 ? frequencySum.reduce(0, +) / Double(sampledCoreCount) : nil,
            efficiency: frequency(0),
            performance: middleExists ? frequency(1) : frequency(2),
            superCore: middleExists ? frequency(2) : nil
        )
    }

    private static func frequencyStates(for key: String) -> [Double]? {
        for name in ["pmgr-child", "pmgr"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(name),
                                               &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var unmanaged: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                      let data = properties[key] as? Data,
                      data.count >= 8, data.count % 8 == 0 else { continue }
                let bytes = [UInt8](data)
                let values = stride(from: 0, to: bytes.count, by: 8).map { offset -> Double in
                    let raw = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
                        UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                    return Double(raw) / (raw >= 100_000_000 ? 1_000_000 : 1_000)
                }
                if values.allSatisfy({ (100...8_000).contains($0) }) { return values }
            }
        }
        return nil
    }
}
