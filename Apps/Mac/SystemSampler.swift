import ActivityCore
import AppKit
import Darwin
import DiskArbitration
import CoreWLAN
import Foundation
import IOKit
import IOKit.ps
import IOKit.storage
import SystemConfiguration

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
    private var previousNetwork: [String: (received: UInt64, sent: UInt64, date: Date)] = [:]
    private var lastNetworkInterface: String?
    private let networkReader = NetworkAuxReader()
    private var wifiNameAuthorized = false
    private var cachedNetworkAux: NetworkAuxSample?
    private var networkAuxFetching = false
    private var lastNetworkAuxFetch: Date = .distantPast
    private let diskReader = DiskSensorReader()
    private var diskFetching = false
    private var lastDiskFetch: Date = .distantPast
    private var cachedDiskDetails: DiskDetails?
    private var diskUpdateInterval: TimeInterval = 10

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
        refreshDiskIfNeeded(at: date)
        let network = networkRates(at: date)
        if let name = network?.details.interfaceName { refreshNetworkAuxIfNeeded(for: name, at: date) }
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
            ramDetails: memory?.details,
            diskDetails: cachedDiskDetails,
            networkDetails: network?.details
        )
    }

    func setWiFiNameAuthorized(_ authorized: Bool) {
        guard wifiNameAuthorized != authorized else { return }
        wifiNameAuthorized = authorized
        // Never retain a name after access is revoked. An in-flight read uses
        // its captured authorization and is rejected if the state changed.
        cachedNetworkAux = nil
        lastNetworkAuxFetch = .distantPast
    }

    func setDiskSamplingSettings(_ settings: DiskSamplingSettings) {
        guard settings.isValid else { return }
        diskUpdateInterval = TimeInterval(settings.updateInterval)
        lastDiskFetch = .distantPast
        Task.detached(priority: .utility) { [reader = diskReader] in reader.configure(settings) }
    }

    func refreshDiskIfDue() {
        refreshDiskIfNeeded(at: .now)
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

    // Disk Arbitration, driver counters and process enumeration can briefly
    // block (especially for external volumes). Fetch off the UI sampling timer.
    private func refreshDiskIfNeeded(at date: Date) {
        guard !diskFetching, date.timeIntervalSince(lastDiskFetch) >= diskUpdateInterval else { return }
        diskFetching = true
        lastDiskFetch = date
        Task.detached(priority: .utility) { [weak self, reader = diskReader] in
            let details = reader.read()
            await self?.receivedDisk(details)
        }
    }

    private func receivedDisk(_ details: DiskDetails) {
        cachedDiskDetails = details
        diskFetching = false
    }

    private func networkRates(at date: Date) -> (received: Double?, sent: Double?, details: NetworkDetails)? {
        // Route selection comes from SystemConfiguration, not a sum of every
        // en*/bridge/VPN interface. If no primary route exists, report unknown.
        let primaryIPv4 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryIPv6 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        guard let routedName = (primaryIPv4?["PrimaryInterface"] as? String) ??
                               (primaryIPv6?["PrimaryInterface"] as? String), !routedName.isEmpty else {
            lastNetworkInterface = nil
            return nil
        }
        // As in the reference network reader, a VPN's virtual default route
        // should resolve to the active underlying hardware interface.
        let name = Self.physicalInterface(underlying: routedName) ?? routedName
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var totalReceived: UInt64?
        var totalSent: UInt64?
        var ipv4: String?
        var ipv6: String?
        var isActive: Bool?
        var linkSpeed: Double?
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == name,
                  let address = item.pointee.ifa_addr else { continue }
            let flags = item.pointee.ifa_flags
            let family = address.pointee.sa_family
            if family == UInt8(AF_INET), ipv4 == nil {
                var addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &bytes, socklen_t(bytes.count)) != nil {
                    ipv4 = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            } else if family == UInt8(AF_INET6) {
                var addr = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                var bytes = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr, &bytes, socklen_t(bytes.count)) != nil {
                    let candidate = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if ipv6 == nil || (ipv6?.hasPrefix("fe80:") == true && !candidate.hasPrefix("fe80:")) {
                        ipv6 = candidate
                    }
                }
            }
            guard family == UInt8(AF_LINK) else { continue }
            isActive = flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
            guard let data = item.pointee.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            totalReceived = UInt64(counters.ifi_ibytes)
            totalSent = UInt64(counters.ifi_obytes)
            if counters.ifi_baudrate > 0 {
                linkSpeed = Double(counters.ifi_baudrate) / 1_000_000
            }
        }
        var down: Double?
        var up: Double?
        if let totalReceived, let totalSent {
            let previous = previousNetwork[name]
            let elapsed = previous.map { date.timeIntervalSince($0.date) } ?? 0
            // First reading on a new primary, counter rollover, and link loss
            // all invalidate an instantaneous rate, avoiding artificial spikes.
            if name == lastNetworkInterface, isActive == true, elapsed > 0, elapsed <= 10,
               let previous, totalReceived >= previous.received, totalSent >= previous.sent {
                down = Double(totalReceived - previous.received) / elapsed
                up = Double(totalSent - previous.sent) / elapsed
            }
            previousNetwork[name] = (totalReceived, totalSent, date)
        }
        lastNetworkInterface = name

        let aux = cachedNetworkAux?.interfaceName == name ? cachedNetworkAux : nil
        let gateway = (primaryIPv4?["PrimaryInterface"] as? String) == name ?
            primaryIPv4?["Router"] as? String : nil
        let details = NetworkDetails(
            interfaceName: name, displayName: aux?.displayName,
            connectionType: aux?.connectionType, isActive: isActive,
            localIPv4: ipv4, localIPv6: ipv6, gatewayIPv4: aux?.gatewayIPv4 ?? gateway,
            dnsServers: aux?.dnsServers, hardwareAddress: aux?.hardwareAddress,
            ssid: aux?.ssid, wifiRSSI: aux?.wifiRSSI, wifiNoise: aux?.wifiNoise,
            wifiStandard: aux?.wifiStandard, wifiChannel: aux?.wifiChannel,
            linkSpeedMbps: aux?.linkSpeedMbps ?? linkSpeed,
            totalReceivedBytes: totalReceived, totalSentBytes: totalSent,
            // A cached successful probe must not imply current connectivity
            // after the selected interface has become inactive.
            connectivityStatus: isActive == true ? aux?.connectivityStatus : nil,
            latencyMs: isActive == true ? aux?.latencyMs : nil,
            jitterMs: isActive == true ? aux?.jitterMs : nil,
            topProcesses: aux?.topProcesses)
        return (down, up, details)
    }

    private static func isVirtualInterface(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg"].contains {
            name.hasPrefix($0)
        }
    }

    private static func physicalInterface(underlying route: String) -> String? {
        guard isVirtualInterface(route) else { return nil }
        if let setup = SCDynamicStoreCopyValue(nil, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setup["ServiceOrder"] as? [String] {
            for serviceID in order {
                guard let service = SCDynamicStoreCopyValue(
                    nil, "State:/Network/Service/\(serviceID)/IPv4" as CFString
                ) as? [String: Any],
                service["Router"] != nil,
                let name = service["InterfaceName"] as? String,
                !isVirtualInterface(name) else { continue }
                return name
            }
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            if !isVirtualInterface(name) { return name }
        }
        return nil
    }

    private func refreshNetworkAuxIfNeeded(for name: String, at date: Date) {
        guard !networkAuxFetching,
              cachedNetworkAux?.interfaceName != name || date.timeIntervalSince(lastNetworkAuxFetch) >= 6 else { return }
        networkAuxFetching = true
        lastNetworkAuxFetch = date
        let authorized = wifiNameAuthorized
        Task.detached(priority: .utility) { [weak self, reader = networkReader] in
            let info = reader.read(for: name, includeWiFiName: authorized)
            await self?.receivedNetworkAux(info, authorizedAtRead: authorized)
        }
    }

    private func receivedNetworkAux(_ info: NetworkAuxSample, authorizedAtRead: Bool) {
        if authorizedAtRead == wifiNameAuthorized {
            cachedNetworkAux = info
        }
        networkAuxFetching = false
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

/// Slow network details are sampled independently of the two-second telemetry
/// timer. Fields are explicitly tied to the interface for which they were read.
private struct NetworkAuxSample: Sendable {
    let interfaceName: String
    var displayName: String?
    var connectionType: String?
    var gatewayIPv4: String?
    var dnsServers: [String]?
    var hardwareAddress: String?
    var ssid: String?
    var wifiRSSI: Int?
    var wifiNoise: Int?
    var wifiStandard: String?
    var wifiChannel: String?
    var linkSpeedMbps: Double?
    var connectivityStatus: Bool?
    var latencyMs: Double?
    var jitterMs: Double?
    var topProcesses: [NetworkProcess]?
}

/// The caller serializes this reader's invocations; mutable counter baselines
/// remain private to its background utility task.
private final class NetworkAuxReader: @unchecked Sendable {
    private struct ProcessCount {
        let name: String
        let received: UInt64
        let sent: UInt64
        let time: TimeInterval
    }

    private var primary: String?
    private var previousProcesses: [Int: ProcessCount] = [:]
    private var lastProbeTime: TimeInterval = -.infinity
    private var connectivity: Bool?
    private var lastLatency: Double?
    private var jitter: Double?

    func read(for name: String, includeWiFiName: Bool) -> NetworkAuxSample {
        if primary != name {
            primary = name
            previousProcesses.removeAll()
            lastProbeTime = -.infinity
            connectivity = nil
            lastLatency = nil
            jitter = nil
        }
        var details = NetworkAuxSample(interfaceName: name)

        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
           let selected = interfaces.first(where: { (SCNetworkInterfaceGetBSDName($0) as String?) == name }) {
            details.displayName = SCNetworkInterfaceGetLocalizedDisplayName(selected) as String?
            details.hardwareAddress = SCNetworkInterfaceGetHardwareAddressString(selected) as String?
            if let kind = SCNetworkInterfaceGetInterfaceType(selected) {
                switch kind {
                case kSCNetworkInterfaceTypeIEEE80211: details.connectionType = "Wi-Fi"
                case kSCNetworkInterfaceTypeEthernet: details.connectionType = "Ethernet"
                case kSCNetworkInterfaceTypeBluetooth: details.connectionType = "Bluetooth"
                case kSCNetworkInterfaceTypeWWAN: details.connectionType = "Cellular"
                default: details.connectionType = kind as String
                }
            }
        } else if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
            details.connectionType = "Tunnel"
        }

        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        var selectedService: String?
        if global?["PrimaryInterface"] as? String == name {
            details.gatewayIPv4 = global?["Router"] as? String
            selectedService = global?["PrimaryService"] as? String
        } else if let setup = SCDynamicStoreCopyValue(nil, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
                  let order = setup["ServiceOrder"] as? [String] {
            for serviceID in order {
                guard let service = SCDynamicStoreCopyValue(
                    nil, "State:/Network/Service/\(serviceID)/IPv4" as CFString
                ) as? [String: Any],
                service["InterfaceName"] as? String == name,
                let router = service["Router"] as? String else { continue }
                details.gatewayIPv4 = router
                selectedService = serviceID
                break
            }
        }
        if let service = selectedService {
            let stateDNS = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(service)/DNS" as CFString) as? [String: Any]
            let configuredDNS = SCDynamicStoreCopyValue(nil, "Setup:/Network/Service/\(service)/DNS" as CFString) as? [String: Any]
            details.dnsServers = (stateDNS?["ServerAddresses"] as? [String]) ??
                (configuredDNS?["ServerAddresses"] as? [String])
        }

        if details.connectionType == "Wi-Fi",
           let interface = CWWiFiClient.shared().interface(withName: name) {
            if includeWiFiName {
                let ssid = interface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let ssid, !ssid.isEmpty && ssid != "<redacted>" { details.ssid = ssid }
            }
            let rssi = interface.rssiValue()
            if (-110 ... -1).contains(rssi) { details.wifiRSSI = rssi }
            let noise = interface.noiseMeasurement()
            if (-130 ... -1).contains(noise) { details.wifiNoise = noise }
            let transmit = interface.transmitRate()
            if transmit.isFinite && transmit > 0 { details.linkSpeedMbps = transmit }
            switch interface.activePHYMode() {
            case .mode11a: details.wifiStandard = "802.11a"
            case .mode11b: details.wifiStandard = "802.11b"
            case .mode11g: details.wifiStandard = "802.11g"
            case .mode11n: details.wifiStandard = "802.11n"
            case .mode11ac: details.wifiStandard = "802.11ac"
            case .mode11ax: details.wifiStandard = "802.11ax"
            case .mode11be: details.wifiStandard = "802.11be"
            default: break
            }
            if let channel = interface.wlanChannel() {
                let band: String
                switch channel.channelBand {
                case .band2GHz: band = "2.4 GHz"
                case .band5GHz: band = "5 GHz"
                case .band6GHz: band = "6 GHz"
                default: band = "Unknown band"
                }
                let width: String
                switch channel.channelWidth {
                case .width20MHz: width = "20 MHz"
                case .width40MHz: width = "40 MHz"
                case .width80MHz: width = "80 MHz"
                case .width160MHz: width = "160 MHz"
                default: width = "Unknown width"
                }
                details.wifiChannel = "\(channel.channelNumber) (\(band), \(width))"
            }
        }

        details.topProcesses = readTopProcesses()
        updateConnectivityIfDue()
        details.connectivityStatus = connectivity
        details.latencyMs = lastLatency
        details.jitterMs = jitter
        return details
    }

    /// nettop exposes per-process cumulative socket bytes across all interface
    /// types. Unlike interface counters, these figures are not Wi-Fi-only.
    private func readTopProcesses() -> [NetworkProcess]? {
        guard let response = Self.runCommand("/usr/bin/nettop",
                    ["-P", "-L", "1", "-n", "-x", "-s", "1", "-J", "bytes_in,bytes_out"],
                    timeout: 5), response.status == 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        var next: [Int: ProcessCount] = [:]
        var ranked: [NetworkProcess] = []
        for line in response.output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  let marker = columns[0].lastIndex(of: "."),
                  let pid = Int(columns[0][columns[0].index(after: marker)...]), pid > 0,
                  let received = UInt64(columns[1]), let sent = UInt64(columns[2]) else { continue }
            let processName = String(columns[0][..<marker])
            next[pid] = ProcessCount(name: processName, received: received, sent: sent, time: now)
            guard let previous = previousProcesses[pid], previous.name == processName,
                  received >= previous.received, sent >= previous.sent else { continue }
            let elapsed = now - previous.time
            guard elapsed > 0, elapsed < 30 else { continue }
            let rx = Double(received - previous.received) / elapsed
            let tx = Double(sent - previous.sent) / elapsed
            guard rx > 0 || tx > 0 else { continue }
            let name = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? processName
            ranked.append(NetworkProcess(pid: pid, name: name,
                                         receivedBytesPerSecond: rx, sentBytesPerSecond: tx))
        }
        let hadBaseline = !previousProcesses.isEmpty
        previousProcesses = next
        guard hadBaseline else { return nil }
        return Array(ranked.sorted {
            let lhs = max($0.receivedBytesPerSecond ?? 0, $0.sentBytesPerSecond ?? 0)
            let rhs = max($1.receivedBytesPerSecond ?? 0, $1.sentBytesPerSecond ?? 0)
            return lhs == rhs ? $0.pid < $1.pid : lhs > rhs
        }.prefix(8))
    }

    private func updateConnectivityIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProbeTime >= 10 else { return }
        lastProbeTime = now
        // One low-frequency ICMP echo to Cloudflare's 1.1.1.1. This tests the
        // path to that endpoint; a failure does not prove all Internet is down.
        guard let result = Self.runCommand("/sbin/ping",
                                           ["-n", "-c", "1", "-W", "1000", "1.1.1.1"],
                                           timeout: 3) else {
            connectivity = nil
            lastLatency = nil
            jitter = nil
            lastProbeTime = now
            return
        }
        connectivity = result.status == 0
        guard result.status == 0,
              let expression = try? NSRegularExpression(pattern: #"time=([0-9]+(?:\.[0-9]+)?)\s*ms"#),
              let match = expression.firstMatch(in: result.output, range: NSRange(result.output.startIndex..., in: result.output)),
              let range = Range(match.range(at: 1), in: result.output),
              let latency = Double(result.output[range]), latency.isFinite else {
            lastLatency = nil
            jitter = nil
            return
        }
        if let prior = lastLatency {
            let variation = abs(latency - prior)
            jitter = jitter.map { 0.7 * $0 + 0.3 * variation } ?? variation
        }
        lastLatency = latency
    }

    private static func runCommand(_ executable: String, _ arguments: [String],
                                   timeout: TimeInterval) -> (output: String, status: Int32)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ["LC_ALL": "C", "NSUnbufferedIO": "YES"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        guard (try? task.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            if task.isRunning { task.terminate() }
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, task.terminationStatus)
    }
}

/// Samples kernel disk and process counters from a background task. The lock
/// protects the previous measurements if sampling is ever called concurrently.
private final class DiskSensorReader: @unchecked Sendable {
    private struct CounterSample {
        let read: UInt64?
        let written: UInt64?
        let time: TimeInterval
    }

    private struct DeviceActivity {
        let read: UInt64?
        let written: UInt64?
        let readRate: Double?
        let writeRate: Double?
    }

    private struct ProcessSample {
        let start: UInt64
        let read: UInt64
        let written: UInt64
        let time: TimeInterval
    }

    private let lock = NSLock()
    private var deviceSamples: [UInt64: CounterSample] = [:]
    private var processSamples: [pid_t: ProcessSample] = [:]
    private var smartCache: [String: (until: TimeInterval, value: DiskSMART?)] = [:]
    private var ataEnableAttempted = Set<String>()
    private var settings = DiskSamplingSettings()

    func configure(_ settings: DiskSamplingSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
        smartCache.removeAll()
        ataEnableAttempted.removeAll()
        if settings.topProcessCount == 0 { processSamples.removeAll() }
    }

    func read() -> DiskDetails {
        lock.lock()
        defer { lock.unlock() }

        let time = ProcessInfo.processInfo.systemUptime
        let session = DASessionCreate(kCFAllocatorDefault)
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey]
        let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        // Include the startup volume even if the OS omits it from visible mounts.
        var paths: [String: URL] = ["/": URL(fileURLWithPath: "/", isDirectory: true)]
        for url in mounts {
            let path = url.standardizedFileURL.path
            guard path == "/" || (path.hasPrefix("/Volumes/") &&
                                   !path.dropFirst("/Volumes/".count).contains("/")) else { continue }
            // Recovery is a hidden OS volume on some macOS releases.
            guard path != "/Volumes/Recovery" else { continue }
            paths[path] = url
        }

        var activeDrivers = Set<UInt64>()
        var activities: [UInt64: DeviceActivity] = [:]
        var volumes: [DiskVolume] = []
        for (path, url) in paths.sorted(by: { $0.key == "/" || ($1.key != "/" && $0.key < $1.key) }) {
            let disk = session.flatMap { DADiskCreateFromVolumePath(kCFAllocatorDefault, $0, url as CFURL) }
            let description = disk.flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:]
            let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool
            let bsdName = disk.flatMap { DADiskGetBSDName($0).map { String(cString: $0) } }
            let fs = fileSystem(path)
            let resources = try? url.resourceValues(forKeys: Set(keys + [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
            ]))
            let uuid = resources?.volumeUUIDString?.lowercased()
            let id = uuid.map { "volume:\($0)" } ?? "mount:\(bsdName ?? path):\(path)"
            let name = resources?.volumeName ?? (path == "/" ? "Macintosh HD" : url.lastPathComponent)
            let fileSystemName = description[kDADiskDescriptionVolumeKindKey as String] as? String ?? fs?.kind
            let connection = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let total = resources?.volumeTotalCapacity.map { UInt64(max(0, $0)) } ?? fs?.total
            let free = resources?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? fs?.free

            var activity: DeviceActivity?
            if let disk {
                let media = DADiskCopyIOMedia(disk)
                if media != 0 {
                    if let driver = Self.blockDriver(above: media) {
                        var entryID: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(driver, &entryID) == KERN_SUCCESS {
                            activeDrivers.insert(entryID)
                            if let known = activities[entryID] {
                                activity = known
                            } else {
                                let sampled = readDriver(driver, id: entryID, at: time)
                                activities[entryID] = sampled
                                activity = sampled
                            }
                        }
                        IOObjectRelease(driver)
                    }
                    IOObjectRelease(media)
                }
            }

            volumes.append(DiskVolume(
                id: id, name: name, mountPath: path, bsdName: bsdName,
                fileSystem: fileSystemName, connectionType: connection,
                isRemovable: removable,
                totalBytes: total, freeBytes: free,
                readBytesPerSecond: activity?.readRate,
                writeBytesPerSecond: activity?.writeRate,
                totalReadBytes: activity?.read, totalWrittenBytes: activity?.written,
                smart: smartStatus(for: path, bsdName: bsdName, cacheID: id, at: time)
            ))
        }
        deviceSamples = deviceSamples.filter { activeDrivers.contains($0.key) }
        let presentVolumes = Set(volumes.map(\.id))
        smartCache = smartCache.filter { presentVolumes.contains($0.key) }
        return DiskDetails(volumes: volumes,
                           topProcesses: settings.topProcessCount == 0 ? [] : readTopProcesses(at: time))
    }

    private func fileSystem(_ path: String) -> (kind: String, total: UInt64, free: UInt64)? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let kind = withUnsafeBytes(of: info.f_fstypename) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
        let blockSize = UInt64(info.f_bsize)
        let (total, totalOverflow) = UInt64(info.f_blocks).multipliedReportingOverflow(by: blockSize)
        let (free, freeOverflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: blockSize)
        return (kind, totalOverflow ? 0 : total, freeOverflow ? 0 : free)
    }

    private func readDriver(_ driver: io_registry_entry_t, id: UInt64,
                            at time: TimeInterval) -> DeviceActivity {
        let raw = IORegistryEntryCreateCFProperty(driver,
                     kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0)
        let data = raw?.takeRetainedValue() as? [String: Any] ?? [:]
        let read = (data[kIOBlockStorageDriverStatisticsBytesReadKey as String] as? NSNumber)?.uint64Value
        let written = (data[kIOBlockStorageDriverStatisticsBytesWrittenKey as String] as? NSNumber)?.uint64Value
        let previous = deviceSamples[id]
        let duration = previous.map { time - $0.time } ?? 0
        let readRate = Self.rate(current: read, previous: previous?.read, seconds: duration)
        let writeRate = Self.rate(current: written, previous: previous?.written, seconds: duration)
        deviceSamples[id] = CounterSample(read: read, written: written, time: time)
        return DeviceActivity(read: read, written: written,
                              readRate: readRate, writeRate: writeRate)
    }

    private static func rate(current: UInt64?, previous: UInt64?,
                             seconds: TimeInterval) -> Double? {
        guard let current, let previous, current >= previous,
              seconds > 0, seconds.isFinite else { return nil }
        return Double(current - previous) / seconds
    }

    /// Search IOService ancestors for the storage driver responsible for this
    /// media; APFS containers can have multiple parent layers.
    private static func blockDriver(above media: io_registry_entry_t) -> io_registry_entry_t? {
        IOObjectRetain(media)
        var entries = [media]
        defer { entries.forEach { IOObjectRelease($0) } }
        var visited = Set<UInt64>()
        var found: io_registry_entry_t?
        var index = 0
        while index < entries.count && visited.count < 256 {
            let entry = entries[index]
            index += 1
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
            guard visited.insert(id).inserted else { continue }
            if IOObjectConformsTo(entry, kIOBlockStorageDriverClass) != 0 {
                if let found, found != entry { return nil }
                found = entry
                continue
            }
            var parents: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parents) == KERN_SUCCESS else { continue }
            var parent = IOIteratorNext(parents)
            while parent != 0 {
                entries.append(parent)
                parent = IOIteratorNext(parents)
            }
            IOObjectRelease(parents)
        }
        guard let found else { return nil }
        IOObjectRetain(found)
        return found
    }

    /// diskutil exposes some NVMe SMART counters directly for mounted disks.
    /// These keys are explicitly documented by macOS as device-dependent; each
    /// field remains nil when absent, unrecognized, or outside numeric range.
    private func smartStatus(for mountPath: String, bsdName: String?, cacheID: String,
                             at time: TimeInterval) -> DiskSMART? {
        guard settings.smartEnabled else { return nil }
        if let cached = smartCache[cacheID], cached.until > time { return cached.value }
        let info = Self.diskInfo(mountPath) ?? [:]
        let status = (info["SMARTStatus"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var values = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        // Some APFS volumes expose SMART only on their physical store. If a
        // volume resolves to exactly one store, query that physical device.
        if values.isEmpty,
           let stores = info["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
           let partition = stores[0]["APFSPhysicalStore"] as? String,
           let match = partition.range(of: #"^disk[0-9]+"#, options: .regularExpression),
           let physical = Self.diskInfo(String(partition[match])) {
            values = physical["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        }
        if values.isEmpty, settings.ataSMARTEnabled, let bsdName,
           let ata = ataSMART(for: bsdName, status: status) {
            smartCache[cacheID] = (time + TimeInterval(settings.smartUpdateInterval), ata)
            return ata
        }

        func number(_ key: String) -> UInt64? {
            guard let value = values[key] as? NSNumber else { return nil }
            return UInt64(value.stringValue)
        }
        // NVMe SMART counters can occupy two 64-bit words. Only convert when
        // the value fits UInt64; data units represent 512,000 bytes each.
        func counter(_ key: String) -> UInt64? {
            guard let lower = number("\(key)_0"), (number("\(key)_1") ?? 0) == 0 else { return nil }
            return lower
        }
        func dataBytes(_ key: String) -> UInt64? {
            guard let value = counter(key) else { return nil }
            let product = value.multipliedReportingOverflow(by: 512_000)
            return product.overflow ? nil : product.partialValue
        }
        let temperature: Double? = {
            guard let kelvin = number("TEMPERATURE"), (200...500).contains(kelvin) else { return nil }
            return Double(kelvin) - 273.15
        }()
        let health: Double? = {
            guard let used = number("PERCENTAGE_USED") else { return nil }
            return max(0, 100 - Double(used))
        }()
        let spare: Double? = {
            guard let value = number("AVAILABLE_SPARE"), value <= 100 else { return nil }
            return Double(value)
        }()
        let warning = number("CRITICAL_WARNING").map { "0x" + String($0, radix: 16, uppercase: true) }
        let rawRead = dataBytes("DATA_UNITS_READ")
        let rawWritten = dataBytes("DATA_UNITS_WRITTEN")
        let cycles = counter("POWER_CYCLES")
        let hours = counter("POWER_ON_HOURS")
        let smart: DiskSMART? = {
            guard status != nil || temperature != nil || health != nil || spare != nil ||
                    warning != nil || rawRead != nil || rawWritten != nil ||
                    cycles != nil || hours != nil else { return nil }
            return DiskSMART(totalReadBytes: rawRead, totalWrittenBytes: rawWritten,
                             temperatureCelsius: temperature, healthPercent: health,
                             powerCycles: cycles, powerOnHours: hours,
                             criticalWarning: warning, availableSparePercent: spare,
                             status: status)
        }()
        smartCache[cacheID] = (time + TimeInterval(settings.smartUpdateInterval), smart)
        return smart
    }

    private func ataSMART(for bsdName: String, status: String?) -> DiskSMART? {
        let clientID = CFUUIDGetConstantUUIDWithBytes(nil,
            0x24, 0x51, 0x4B, 0x7A, 0x28, 0x04, 0x11, 0xD6,
            0x8A, 0x02, 0x00, 0x30, 0x65, 0x70, 0x48, 0x66)
        let interfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
            0x08, 0xAB, 0xE2, 0x1C, 0x20, 0xD4, 0x11, 0xD6,
            0x8D, 0xF6, 0x00, 0x03, 0x93, 0x5A, 0x76, 0xB2)
        let pluginID = CFUUIDGetConstantUUIDWithBytes(nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        var device = IOServiceGetMatchingService(kIOMainPortDefault,
            IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard device != 0 else { return nil }
        while IOObjectConformsTo(device, kIOBlockStorageDeviceClass) == 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(device, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { IOObjectRelease(device); return nil }
            IOObjectRelease(device)
            device = parent
        }
        defer { IOObjectRelease(device) }
        guard let capability = IORegistryEntryCreateCFProperty(device, "SMART Capable" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
              capability else { return nil }

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var smartInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOATASMARTInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, clientID, pluginID,
                                               &plugin, &score) == KERN_SUCCESS else { return nil }
        defer { if plugin != nil { IODestroyPlugInInterface(plugin) } }
        let query = withUnsafeMutablePointer(to: &smartInterface) {
            $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
                plugin?.pointee?.pointee.QueryInterface(plugin,
                    CFUUIDGetUUIDBytes(interfaceID), $0) ?? KERN_NOT_FOUND
            }
        }
        guard query == KERN_SUCCESS else { return nil }
        defer { if smartInterface != nil { _ = plugin?.pointee?.pointee.Release(smartInterface) } }
        guard let smart = smartInterface?.pointee else { return nil }
        var data = ATASMARTData()
        var result = smart.pointee.SMARTReadData(smartInterface, &data)
        if result != KERN_SUCCESS && ataEnableAttempted.insert(bsdName).inserted {
            _ = smart.pointee.SMARTEnableDisableOperations(smartInterface, true)
            result = smart.pointee.SMARTReadData(smartInterface, &data)
        }
        guard result == KERN_SUCCESS else { return nil }

        var attributes: [Int: (current: Int, raw: UInt64)] = [:]
        withUnsafeBytes(of: &data) { bytes in
            for index in 0..<30 {
                let offset = 2 + index * 12
                guard offset + 11 <= bytes.count else { break }
                let id = Int(bytes[offset])
                guard id != 0 else { continue }
                var raw: UInt64 = 0
                for byte in 0..<6 { raw |= UInt64(bytes[offset + 5 + byte]) << (8 * byte) }
                attributes[id] = (Int(bytes[offset + 3]), raw)
            }
        }
        let temperature = attributes[194]?.raw ?? attributes[190]?.raw
        let life = [231, 202, 177, 173, 169, 233].compactMap { attributes[$0]?.current }.first
        return DiskSMART(temperatureCelsius: temperature.map { Double($0 & 0xFF) },
                         healthPercent: life.map { Double(min(100, max(0, $0))) },
                         powerCycles: attributes[12]?.raw,
                         powerOnHours: attributes[9]?.raw,
                         status: status)
    }

    private static func diskInfo(_ path: String) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "-plist", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func readTopProcesses(at time: TimeInterval) -> [DiskProcess]? {
        // proc_pid_rusage returns kernel-measured cumulative disk I/O per PID.
        // The second sample produces rates; inaccessible PIDs are omitted.
        let requested = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requested > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(requested) / MemoryLayout<pid_t>.stride + 256)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        var next: [pid_t: ProcessSample] = [:]
        var activity: [(pid: pid_t, readRate: Double, writeRate: Double)] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }
            let now = ProcessSample(start: usage.ri_proc_start_abstime,
                                    read: usage.ri_diskio_bytesread,
                                    written: usage.ri_diskio_byteswritten, time: time)
            next[pid] = now
            guard let old = processSamples[pid], old.start == now.start else { continue }
            guard let readRate = Self.rate(current: now.read, previous: old.read, seconds: time - old.time),
                  let writeRate = Self.rate(current: now.written, previous: old.written, seconds: time - old.time),
                  readRate > 0 || writeRate > 0 else { continue }
            activity.append((pid, readRate, writeRate))
        }
        let hasBaseline = !processSamples.isEmpty
        processSamples = next
        guard hasBaseline else { return nil }
        return activity.sorted {
            let lhs = max($0.readRate, $0.writeRate)
            let rhs = max($1.readRate, $1.writeRate)
            return lhs == rhs ? $0.pid < $1.pid : lhs > rhs
        }.prefix(settings.topProcessCount).map { item in
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let length = proc_name(item.pid, &nameBuffer, UInt32(nameBuffer.count))
            let executable = length > 0 ? String(decoding: nameBuffer.prefix(while: { $0 != 0 })
                                                      .map { UInt8(bitPattern: $0) }, as: UTF8.self) : "PID \(item.pid)"
            let name = NSRunningApplication(processIdentifier: item.pid)?.localizedName ?? executable
            return DiskProcess(pid: Int(item.pid), name: name,
                               readBytesPerSecond: item.readRate,
                               writeBytesPerSecond: item.writeRate)
        }
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
