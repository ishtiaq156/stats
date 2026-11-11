import Foundation

public struct MetricSnapshot: Codable, Sendable, Equatable {
    public static let protocolVersion = 1

    public let version: Int
    public let machineName: String
    public let timestamp: Date
    public let cpuFraction: Double?
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    public let diskFreeBytes: UInt64?
    public let diskTotalBytes: UInt64?
    public let networkReceivedBytesPerSecond: Double?
    public let networkSentBytesPerSecond: Double?
    public let batteryFraction: Double?
    public let isCharging: Bool?
    // Optional so existing macOS companions and saved history remain decodable.
    public let cpuDetails: CPUDetails?
    public let ramDetails: RAMDetails?
    public let diskDetails: DiskDetails?
    public let networkDetails: NetworkDetails?

    public init(
        machineName: String,
        timestamp: Date = .now,
        cpuFraction: Double? = nil,
        memoryUsedBytes: UInt64? = nil,
        memoryTotalBytes: UInt64? = nil,
        diskFreeBytes: UInt64? = nil,
        diskTotalBytes: UInt64? = nil,
        networkReceivedBytesPerSecond: Double? = nil,
        networkSentBytesPerSecond: Double? = nil,
        batteryFraction: Double? = nil,
        isCharging: Bool? = nil,
        cpuDetails: CPUDetails? = nil,
        ramDetails: RAMDetails? = nil,
        diskDetails: DiskDetails? = nil,
        networkDetails: NetworkDetails? = nil
    ) {
        self.version = Self.protocolVersion
        self.machineName = machineName
        self.timestamp = timestamp
        self.cpuFraction = cpuFraction
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond
        self.networkSentBytesPerSecond = networkSentBytesPerSecond
        self.batteryFraction = batteryFraction
        self.isCharging = isCharging
        self.cpuDetails = cpuDetails
        self.ramDetails = ramDetails
        self.diskDetails = diskDetails
        self.networkDetails = networkDetails
    }

    /// Keep history compact. The CPU and RAM history charts use only aggregate
    /// fractions/bytes; per-volume disk history uses IDs and rates. Network
    /// history uses aggregate received/sent rates. Live snapshots retain details.
    public func withoutCPUProcesses() -> MetricSnapshot {
        MetricSnapshot(machineName: machineName, timestamp: timestamp, cpuFraction: cpuFraction,
                       memoryUsedBytes: memoryUsedBytes, memoryTotalBytes: memoryTotalBytes,
                       diskFreeBytes: diskFreeBytes, diskTotalBytes: diskTotalBytes,
                       networkReceivedBytesPerSecond: networkReceivedBytesPerSecond,
                       networkSentBytesPerSecond: networkSentBytesPerSecond,
                       batteryFraction: batteryFraction, isCharging: isCharging,
                       diskDetails: diskDetails?.withoutProcesses())
    }
}

public struct NetworkProcess: Codable, Sendable, Equatable, Identifiable {
    public let pid: Int
    public let name: String
    public let receivedBytesPerSecond: Double?
    public let sentBytesPerSecond: Double?
    public var id: Int { pid }

    public init(pid: Int, name: String, receivedBytesPerSecond: Double? = nil,
                sentBytesPerSecond: Double? = nil) {
        self.pid = pid
        self.name = name
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
    }
}

/// Details for the primary interface selected by macOS. Total bytes are
/// interface counters since boot (or the interface's most recent reset).
/// Per-process byte rates are system-wide socket activity from `nettop`.
public struct NetworkDetails: Codable, Sendable, Equatable {
    public let interfaceName: String?
    public let displayName: String?
    public let connectionType: String?
    public let isActive: Bool?
    public let localIPv4: String?
    public let localIPv6: String?
    public let gatewayIPv4: String?
    public let dnsServers: [String]?
    public let hardwareAddress: String?
    public let ssid: String?
    public let wifiRSSI: Int?
    public let wifiNoise: Int?
    public let wifiStandard: String?
    public let wifiChannel: String?
    public let linkSpeedMbps: Double?
    public let totalReceivedBytes: UInt64?
    public let totalSentBytes: UInt64?
    /// ICMP reachability of the configured probe endpoint, not global Internet health.
    public let connectivityStatus: Bool?
    public let latencyMs: Double?
    /// Absolute difference between consecutive successful ICMP round trips.
    public let jitterMs: Double?
    public let topProcesses: [NetworkProcess]?

    public init(interfaceName: String? = nil, displayName: String? = nil,
                connectionType: String? = nil, isActive: Bool? = nil,
                localIPv4: String? = nil, localIPv6: String? = nil,
                gatewayIPv4: String? = nil, dnsServers: [String]? = nil,
                hardwareAddress: String? = nil, ssid: String? = nil,
                wifiRSSI: Int? = nil, wifiNoise: Int? = nil,
                wifiStandard: String? = nil, wifiChannel: String? = nil,
                linkSpeedMbps: Double? = nil, totalReceivedBytes: UInt64? = nil,
                totalSentBytes: UInt64? = nil, connectivityStatus: Bool? = nil,
                latencyMs: Double? = nil, jitterMs: Double? = nil,
                topProcesses: [NetworkProcess]? = nil) {
        self.interfaceName = interfaceName
        self.displayName = displayName
        self.connectionType = connectionType
        self.isActive = isActive
        self.localIPv4 = localIPv4
        self.localIPv6 = localIPv6
        self.gatewayIPv4 = gatewayIPv4
        self.dnsServers = dnsServers
        self.hardwareAddress = hardwareAddress
        self.ssid = ssid
        self.wifiRSSI = wifiRSSI
        self.wifiNoise = wifiNoise
        self.wifiStandard = wifiStandard
        self.wifiChannel = wifiChannel
        self.linkSpeedMbps = linkSpeedMbps
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
        self.connectivityStatus = connectivityStatus
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.topProcesses = topProcesses
    }
}

public struct DiskProcess: Codable, Sendable, Equatable, Identifiable {
    public let pid: Int
    public let name: String
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?
    public var id: Int { pid }

    public init(pid: Int, name: String, readBytesPerSecond: Double? = nil,
                writeBytesPerSecond: Double? = nil) {
        self.pid = pid
        self.name = name
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

/// Drive-provided SMART telemetry. A verified SMART status does not imply
/// measured health percentage, zero critical warnings, or an endurance reading.
public struct DiskSMART: Codable, Sendable, Equatable {
    public let totalReadBytes: UInt64?
    public let totalWrittenBytes: UInt64?
    public let temperatureCelsius: Double?
    public let healthPercent: Double?
    public let powerCycles: UInt64?
    public let powerOnHours: UInt64?
    public let criticalWarning: String?
    public let availableSparePercent: Double?
    public let status: String?

    public init(totalReadBytes: UInt64? = nil, totalWrittenBytes: UInt64? = nil,
                temperatureCelsius: Double? = nil, healthPercent: Double? = nil,
                powerCycles: UInt64? = nil, powerOnHours: UInt64? = nil,
                criticalWarning: String? = nil, availableSparePercent: Double? = nil,
                status: String? = nil) {
        self.totalReadBytes = totalReadBytes
        self.totalWrittenBytes = totalWrittenBytes
        self.temperatureCelsius = temperatureCelsius
        self.healthPercent = healthPercent
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.criticalWarning = criticalWarning
        self.availableSparePercent = availableSparePercent
        self.status = status
    }
}

public struct DiskVolume: Codable, Sendable, Equatable, Identifiable {
    /// Stable volume identifier (prefer filesystem UUID, else mount device/path).
    public let id: String
    public let name: String
    public let mountPath: String
    public let bsdName: String?
    public let fileSystem: String?
    public let connectionType: String?
    public let totalBytes: UInt64?
    public let freeBytes: UInt64?
    /// Physical block-device activity; APFS volumes sharing a device may share rates.
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?
    public let totalReadBytes: UInt64?
    public let totalWrittenBytes: UInt64?
    public let smart: DiskSMART?

    public init(id: String, name: String, mountPath: String,
                bsdName: String? = nil, fileSystem: String? = nil,
                connectionType: String? = nil, totalBytes: UInt64? = nil,
                freeBytes: UInt64? = nil, readBytesPerSecond: Double? = nil,
                writeBytesPerSecond: Double? = nil, totalReadBytes: UInt64? = nil,
                totalWrittenBytes: UInt64? = nil, smart: DiskSMART? = nil) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
        self.bsdName = bsdName
        self.fileSystem = fileSystem
        self.connectionType = connectionType
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.totalReadBytes = totalReadBytes
        self.totalWrittenBytes = totalWrittenBytes
        self.smart = smart
    }

    /// Only data needed for historical per-volume rate charts.
    public func withoutMetadata() -> DiskVolume {
        // Historical records are joined to live volume metadata by `id`.
        // Remove potentially long volume names and mount paths from 900 samples.
        DiskVolume(id: id, name: "", mountPath: "",
                   readBytesPerSecond: readBytesPerSecond,
                   writeBytesPerSecond: writeBytesPerSecond)
    }
}

public struct DiskDetails: Codable, Sendable, Equatable {
    public let volumes: [DiskVolume]
    public let topProcesses: [DiskProcess]?

    public init(volumes: [DiskVolume], topProcesses: [DiskProcess]? = nil) {
        self.volumes = volumes
        self.topProcesses = topProcesses
    }

    /// A bounded list is essential for the 900-sample encrypted history.
    public func withoutProcesses() -> DiskDetails {
        DiskDetails(volumes: Array(volumes.prefix(4)).map { $0.withoutMetadata() })
    }
}

/// Preserves a 900-sample time window and reduces the wire response only when
/// required by the encrypted packet limit. Historical rates remain per-volume.
public struct MetricHistoryBuffer: Sendable {
    private var stored: [MetricSnapshot] = []
    private var individualLengths: [Int] = []
    private var encodedArrayBytes = 2 // JSON array brackets; commas are budgeted below.

    public init() {}

    public var storedSampleCount: Int { stored.count }

    public var snapshots: [MetricSnapshot] {
        let budget = 950_000
        guard encodedArrayBytes + 28 > budget else { return stored }
        guard stored.count > 1 else {
            return encodedArrayBytes + 28 <= budget ? stored : []
        }
        // Keep both ends of the 30-minute window and choose the largest
        // evenly-spaced response that fits; do not immediately halve the
        // sample density when only a few bytes need to be removed.
        var lower = 2
        var upper = stored.count
        var best: [Int] = []
        while lower <= upper {
            let count = lower + (upper - lower) / 2
            let indices = (0..<count).map { $0 * (stored.count - 1) / (count - 1) }
            let bytes = 2 + 28 + indices.reduce(0) { $0 + individualLengths[$1] + 1 }
            if bytes <= budget {
                best = indices
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        if !best.isEmpty { return best.map { stored[$0] } }
        // A pathological single record can exceed the entire packet budget.
        let first = individualLengths[0]
        let last = individualLengths[stored.count - 1]
        if 2 + 28 + first + last + 2 <= budget { return [stored[0], stored[stored.count - 1]] }
        return last + 2 + 28 <= budget ? [stored[stored.count - 1]] : []
    }

    public mutating func append(_ snapshot: MetricSnapshot) {
        let compact = snapshot.withoutCPUProcesses()
        guard let size = try? JSONEncoder().encode(compact).count else { return }
        stored.append(compact)
        individualLengths.append(size)
        // One additional byte per member conservatively accounts for commas.
        encodedArrayBytes += size + 1
        while stored.count > 900 {
            stored.removeFirst()
            encodedArrayBytes -= individualLengths.removeFirst() + 1
        }
    }
}

public struct RAMProcess: Codable, Sendable, Equatable, Identifiable {
    public let pid: Int
    public let name: String
    /// Memory footprint shown by macOS `top`'s MEM column, in bytes.
    public let residentBytes: UInt64
    public var id: Int { pid }

    public init(pid: Int, name: String, residentBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.residentBytes = residentBytes
    }
}

/// Memory composition and virtual-memory metrics sampled on macOS.
/// Optional fields remain absent if the source sysctl fails or is unavailable.
public struct RAMDetails: Codable, Sendable, Equatable {
    public let appBytes: UInt64?
    public let wiredBytes: UInt64?
    public let compressedBytes: UInt64?
    public let freeBytes: UInt64?
    public let cacheBytes: UInt64?
    public let activeBytes: UInt64?
    public let inactiveBytes: UInt64?
    public let swapTotalBytes: UInt64?
    public let swapUsedBytes: UInt64?
    public let swapFreeBytes: UInt64?
    /// "normal", "warning", "critical", or nil when the pressure sysctl fails.
    public let pressureLevel: String?
    /// Cumulative virtual-memory swap page counts since boot.
    public let swapIns: UInt64?
    public let swapOuts: UInt64?
    public let topProcesses: [RAMProcess]?

    public init(appBytes: UInt64? = nil, wiredBytes: UInt64? = nil,
                compressedBytes: UInt64? = nil, freeBytes: UInt64? = nil,
                cacheBytes: UInt64? = nil, activeBytes: UInt64? = nil,
                inactiveBytes: UInt64? = nil, swapTotalBytes: UInt64? = nil,
                swapUsedBytes: UInt64? = nil, swapFreeBytes: UInt64? = nil,
                pressureLevel: String? = nil, swapIns: UInt64? = nil,
                swapOuts: UInt64? = nil, topProcesses: [RAMProcess]? = nil) {
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.freeBytes = freeBytes
        self.cacheBytes = cacheBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapFreeBytes = swapFreeBytes
        self.pressureLevel = pressureLevel
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.topProcesses = topProcesses
    }

    public func withoutProcesses() -> RAMDetails {
        RAMDetails(appBytes: appBytes, wiredBytes: wiredBytes,
                   compressedBytes: compressedBytes, freeBytes: freeBytes,
                   cacheBytes: cacheBytes, activeBytes: activeBytes,
                   inactiveBytes: inactiveBytes, swapTotalBytes: swapTotalBytes,
                   swapUsedBytes: swapUsedBytes, swapFreeBytes: swapFreeBytes,
                   pressureLevel: pressureLevel, swapIns: swapIns, swapOuts: swapOuts)
    }
}

public struct CPUProcess: Codable, Sendable, Equatable, Identifiable {
    public let pid: Int
    public let name: String
    /// The process CPU usage as a percent of one logical CPU; may exceed 100%.
    public let usagePercent: Double
    public var id: Int { pid }

    public init(pid: Int, name: String, usagePercent: Double) {
        self.pid = pid
        self.name = name
        self.usagePercent = usagePercent
    }
}

/// CPU values sampled on the Mac. Fractions range from 0 through 1 unless otherwise noted.
/// The optional fields support older companion builds and hardware-dependent availability.
public struct CPUDetails: Codable, Sendable, Equatable {
    public let userFraction: Double?
    public let systemFraction: Double?
    public let idleFraction: Double?
    public let perCoreFractions: [Double]?
    /// Core classifications in perCoreFractions order: efficiency, performance, super, or unknown.
    public let coreTypes: [String]?
    public let physicalCores: Int?
    public let logicalCores: Int?
    public let efficiencyCores: Int?
    public let performanceCores: Int?
    public let superCores: Int?
    /// BSD load averages in 1-, 5- and 15-minute order.
    public let loadAverages: [Double]?
    public let uptimeSeconds: TimeInterval?
    public let temperatureCelsius: Double?
    public let frequencyMHz: Double?
    public let efficiencyFrequencyMHz: Double?
    public let performanceFrequencyMHz: Double?
    public let superFrequencyMHz: Double?
    public let topProcesses: [CPUProcess]?

    public init(userFraction: Double? = nil, systemFraction: Double? = nil,
                idleFraction: Double? = nil, perCoreFractions: [Double]? = nil,
                coreTypes: [String]? = nil, physicalCores: Int? = nil,
                logicalCores: Int? = nil, efficiencyCores: Int? = nil,
                performanceCores: Int? = nil, superCores: Int? = nil,
                loadAverages: [Double]? = nil,
                uptimeSeconds: TimeInterval? = nil, temperatureCelsius: Double? = nil,
                frequencyMHz: Double? = nil,
                efficiencyFrequencyMHz: Double? = nil,
                performanceFrequencyMHz: Double? = nil,
                superFrequencyMHz: Double? = nil,
                topProcesses: [CPUProcess]? = nil) {
        self.userFraction = userFraction
        self.systemFraction = systemFraction
        self.idleFraction = idleFraction
        self.perCoreFractions = perCoreFractions
        self.coreTypes = coreTypes
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.efficiencyCores = efficiencyCores
        self.performanceCores = performanceCores
        self.superCores = superCores
        self.loadAverages = loadAverages
        self.uptimeSeconds = uptimeSeconds
        self.temperatureCelsius = temperatureCelsius
        self.frequencyMHz = frequencyMHz
        self.efficiencyFrequencyMHz = efficiencyFrequencyMHz
        self.performanceFrequencyMHz = performanceFrequencyMHz
        self.superFrequencyMHz = superFrequencyMHz
        self.topProcesses = topProcesses
    }

    public func withoutProcesses() -> CPUDetails {
        CPUDetails(userFraction: userFraction, systemFraction: systemFraction,
                   idleFraction: idleFraction, perCoreFractions: perCoreFractions,
                   coreTypes: coreTypes, physicalCores: physicalCores,
                   logicalCores: logicalCores, efficiencyCores: efficiencyCores,
                   performanceCores: performanceCores, superCores: superCores,
                   loadAverages: loadAverages,
                   uptimeSeconds: uptimeSeconds, temperatureCelsius: temperatureCelsius,
                   frequencyMHz: frequencyMHz,
                   efficiencyFrequencyMHz: efficiencyFrequencyMHz,
                   performanceFrequencyMHz: performanceFrequencyMHz,
                   superFrequencyMHz: superFrequencyMHz)
    }
}

public struct MacAboutInfo: Codable, Sendable, Equatable {
    public let modelName: String
    public let chip: String?
    public let memory: String?
    public let startupDisk: String?
    public let serialNumber: String?
    public let macOS: String
    public let imagePNG: Data?

    public init(modelName: String, chip: String?, memory: String?, startupDisk: String?,
                serialNumber: String?, macOS: String, imagePNG: Data?) {
        self.modelName = modelName
        self.chip = chip
        self.memory = memory
        self.startupDisk = startupDisk
        self.serialNumber = serialNumber
        self.macOS = macOS
        self.imagePNG = imagePNG
    }
}

public enum MetricFormat {
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return (fraction * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    /// Display RAM in macOS-style binary units.
    /// Disk and network size labels continue using the existing file-size format.
    public static func ramBytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    public static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) + "/s"
    }
}
