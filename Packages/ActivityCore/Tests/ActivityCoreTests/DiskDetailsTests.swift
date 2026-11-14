import Foundation
import XCTest
@testable import ActivityCore

final class DiskDetailsTests: XCTestCase {
    private func volume(_ index: Int, name: String = "External SSD") -> DiskVolume {
        DiskVolume(id: "disk-volume-\(index)-00000000-0000-0000-0000-000000000000",
                   name: name, mountPath: "/Volumes/\(name)", bsdName: "disk\(index)s1",
                   fileSystem: "apfs", connectionType: "USB",
                   totalBytes: 2_000_000, freeBytes: 1_000_000,
                   readBytesPerSecond: 15_000, writeBytesPerSecond: 9_000,
                   totalReadBytes: 4_000_000, totalWrittenBytes: 2_000_000,
                   smart: DiskSMART(totalReadBytes: 8_000_000,
                                    totalWrittenBytes: 7_000_000,
                                    temperatureCelsius: 35.5, healthPercent: 97,
                                    powerCycles: 45, powerOnHours: 5_400,
                                    criticalWarning: "0x02", availableSparePercent: 94,
                                    status: "Verified"))
    }

    func testSnapshotRoundTripPreservesDiskAndProcessTelemetry() throws {
        let disk = DiskDetails(volumes: [volume(2), volume(3)], topProcesses: [
            DiskProcess(pid: 201, name: "Browser Helper", readBytesPerSecond: 100,
                        writeBytesPerSecond: 25)
        ])
        let sample = MetricSnapshot(machineName: "Mac", diskFreeBytes: 1_000_000,
                                    diskTotalBytes: 2_000_000, diskDetails: disk)
        let restored = try JSONDecoder().decode(MetricSnapshot.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(restored, sample)
        XCTAssertEqual(restored.diskDetails?.volumes.count, 2)
        XCTAssertEqual(restored.diskDetails?.volumes[0].smart?.status, "Verified")
        XCTAssertEqual(restored.diskDetails?.volumes[0].smart?.criticalWarning, "0x02")
        XCTAssertEqual(restored.diskDetails?.topProcesses?.first?.readBytesPerSecond, 100)
    }

    func testOlderSnapshotJSONWithoutDiskDetailsStillDecodes() throws {
        let legacy = Data(#"{"version":1,"machineName":"Mac","timestamp":0,"diskFreeBytes":100,"diskTotalBytes":200}"#.utf8)
        let snapshot = try JSONDecoder().decode(MetricSnapshot.self, from: legacy)
        XCTAssertNil(snapshot.diskDetails)
        XCTAssertEqual(snapshot.diskFreeBytes, 100)
        XCTAssertEqual(snapshot.diskTotalBytes, 200)
        XCTAssertEqual(snapshot.version, MetricSnapshot.protocolVersion)
    }

    func testRemovableDiskClassificationDecodesAcrossCompanionVersions() throws {
        let current = DiskVolume(id: "image", name: "Installer", mountPath: "/Volumes/Installer",
                                 isRemovable: true)
        let encoded = try JSONEncoder().encode(current)
        XCTAssertEqual(try JSONDecoder().decode(DiskVolume.self, from: encoded).isRemovable, true)

        let older = Data(#"{"id":"image","name":"Installer","mountPath":"/Volumes/Installer"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DiskVolume.self, from: older).isRemovable)
    }

    func testDiskSamplingSettingsValidateSupportedValues() throws {
        let settings = DiskSamplingSettings(updateInterval: 1, smartEnabled: false,
                                            smartUpdateInterval: 60, ataSMARTEnabled: true,
                                            topProcessCount: 15)
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(try JSONDecoder().decode(DiskSamplingSettings.self,
                        from: JSONEncoder().encode(settings)), settings)
        XCTAssertFalse(DiskSamplingSettings(updateInterval: 4).isValid)
        XCTAssertFalse(DiskSamplingSettings(updateInterval: 30, smartUpdateInterval: 10).isValid)
        XCTAssertFalse(DiskSamplingSettings(topProcessCount: 16).isValid)
    }

    func testHistoricalSnapshotRetainsBoundedRatesAndRemovesMetadata() {
        let longName = String(repeating: "Long Volume Name ", count: 100)
        let volumes = (0..<9).map { volume($0, name: longName) }
        let details = DiskDetails(volumes: volumes,
                                  topProcesses: [DiskProcess(pid: 4, name: "Writer", writeBytesPerSecond: 800)])
        let original = MetricSnapshot(machineName: "Mac", diskDetails: details)
        let history = original.withoutCPUProcesses()

        XCTAssertNil(history.diskDetails?.topProcesses)
        XCTAssertEqual(history.diskDetails?.volumes.count, 4)
        XCTAssertEqual(history.diskDetails?.volumes.first?.id, volumes.first?.id)
        XCTAssertEqual(history.diskDetails?.volumes.first?.readBytesPerSecond, 15_000)
        XCTAssertEqual(history.diskDetails?.volumes.first?.writeBytesPerSecond, 9_000)
        XCTAssertEqual(history.diskDetails?.volumes.first?.name, "")
        XCTAssertEqual(history.diskDetails?.volumes.first?.mountPath, "")
        XCTAssertNil(history.diskDetails?.volumes.first?.bsdName)
        XCTAssertNil(history.diskDetails?.volumes.first?.smart)
        XCTAssertNil(history.diskDetails?.volumes.first?.totalReadBytes)
        XCTAssertNil(history.diskDetails?.volumes.first?.totalBytes)
    }

    func testNineHundredHistoricalSamplesFitEncryptedFrameBudget() throws {
        // Reserve the AES-GCM 28-byte nonce/tag overhead when checking the
        // one-megabyte frame reader limit. IDs intentionally span 64 bytes.
        let volumes = (0..<6).map { index in
            DiskVolume(id: "volume:\(String(repeating: String(index), count: 64))",
                       name: String(repeating: "Very long volume name", count: 100),
                       mountPath: "/Volumes/\(String(repeating: "long directory ", count: 200))",
                       readBytesPerSecond: 9_123_456_789.1234,
                       writeBytesPerSecond: 8_123_456_789.1234,
                       totalReadBytes: UInt64.max, totalWrittenBytes: UInt64.max,
                       smart: DiskSMART(status: "Verified"))
        }
        let cpu = CPUDetails(userFraction: 0.123456, systemFraction: 0.222222,
                             idleFraction: 0.654322,
                             perCoreFractions: Array(repeating: 0.1234567891234, count: 16),
                             coreTypes: Array(repeating: "efficiency", count: 16),
                             physicalCores: 16, logicalCores: 16,
                             loadAverages: [1.123456, 4.123456, 5.123456],
                             uptimeSeconds: 456_789.1234)
        let snapshot = MetricSnapshot(machineName: "Mac Mini", cpuFraction: 0.123456789,
                                      memoryUsedBytes: 14_123_456_789,
                                      memoryTotalBytes: 16_123_456_789,
                                      diskFreeBytes: 999_123_456_789,
                                      diskTotalBytes: 1_123_456_789_123,
                                      cpuDetails: cpu,
                                      diskDetails: DiskDetails(volumes: volumes))
        var history = MetricHistoryBuffer()
        for _ in 0..<900 { history.append(snapshot) }
        let bytes = try JSONEncoder().encode(history.snapshots).count + 28
        XCTAssertEqual(history.storedSampleCount, 900)
        XCTAssertEqual(history.snapshots.count, 900,
                       "compact details should preserve full resolution under this load")
        XCTAssertFalse(history.snapshots.isEmpty)
        XCTAssertNil(history.snapshots.first?.diskDetails?.topProcesses)
        XCTAssertEqual(history.snapshots.first?.diskDetails?.volumes.count, 4)
        XCTAssertLessThanOrEqual(bytes, 1_000_000, "encrypted history exceeds SecurePacket.length limit")
    }

    func testOversizedHistoryRetainsOldestAndNewestTimeline() throws {
        let slowWireID = String(repeating: "real-volume-id-", count: 50)
        let volumes = (0..<4).map { index in
            DiskVolume(id: "\(slowWireID)\(index)", name: "Disk \(index)",
                       mountPath: "/Volumes/Disk\(index)",
                       readBytesPerSecond: Double(index * 1_000),
                       writeBytesPerSecond: 23_456.7)
        }
        let start = Date(timeIntervalSince1970: 500)
        var history = MetricHistoryBuffer()
        for tick in 0..<900 {
            history.append(MetricSnapshot(machineName: "Mac",
                                          timestamp: start.addingTimeInterval(Double(tick * 2)),
                                          cpuFraction: Double(tick % 100) / 100,
                                          diskDetails: DiskDetails(volumes: volumes)))
        }

        XCTAssertEqual(history.storedSampleCount, 900)
        let response = history.snapshots
        XCTAssertLessThan(response.count, 900, "large records should be downsampled")
        XCTAssertGreaterThan(response.count, 1)
        XCTAssertEqual(response.first?.timestamp, start)
        XCTAssertEqual(response.last?.timestamp, start.addingTimeInterval(Double(899 * 2)))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(response).count + 28, 1_000_000)
    }
}
