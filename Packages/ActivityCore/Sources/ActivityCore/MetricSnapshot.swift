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
        ramDetails: RAMDetails? = nil
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
    }

    /// Keep history compact: retain CPU summaries but discard RAM details and
    /// momentary CPU process rankings. Aggregate RAM used/total remains available.
    public func withoutCPUProcesses() -> MetricSnapshot {
        MetricSnapshot(machineName: machineName, timestamp: timestamp, cpuFraction: cpuFraction,
                       memoryUsedBytes: memoryUsedBytes, memoryTotalBytes: memoryTotalBytes,
                       diskFreeBytes: diskFreeBytes, diskTotalBytes: diskTotalBytes,
                       networkReceivedBytesPerSecond: networkReceivedBytesPerSecond,
                       networkSentBytesPerSecond: networkSentBytesPerSecond,
                       batteryFraction: batteryFraction, isCharging: isCharging,
                       cpuDetails: cpuDetails?.withoutProcesses())
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
