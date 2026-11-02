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
        cpuDetails: CPUDetails? = nil
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
    }

    /// Exclude momentary process rankings from the history response to keep it compact.
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

    public static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) + "/s"
    }
}
