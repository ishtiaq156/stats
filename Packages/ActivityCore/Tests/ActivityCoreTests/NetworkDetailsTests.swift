import Foundation
import XCTest
@testable import ActivityCore

final class NetworkDetailsTests: XCTestCase {
    func testNetworkDetailsRoundTripPreservesMeasuredFields() throws {
        let details = NetworkDetails(
            interfaceName: "en1", displayName: "Wi-Fi", connectionType: "Wi-Fi",
            isActive: true, localIPv4: "192.168.1.50", localIPv6: "2001:db8::42",
            gatewayIPv4: "192.168.1.1", dnsServers: ["1.1.1.1", "1.0.0.1"],
            hardwareAddress: "00:11:22:33:44:55", ssid: "Lab Network",
            wifiRSSI: -47, wifiNoise: -92, wifiStandard: "802.11ax",
            wifiChannel: "149 (5 GHz, 80 MHz)", linkSpeedMbps: 864,
            totalReceivedBytes: 42_000_000, totalSentBytes: 32_000_000,
            connectivityStatus: true, latencyMs: 14.7, jitterMs: 1.2,
            topProcesses: [NetworkProcess(pid: 112, name: "Browser",
                                          receivedBytesPerSecond: 123_400,
                                          sentBytesPerSecond: 18_200)]
        )
        let snapshot = MetricSnapshot(machineName: "Mac", networkReceivedBytesPerSecond: 450_000,
                                      networkSentBytesPerSecond: 19_000, networkDetails: details)
        let decoded = try JSONDecoder().decode(MetricSnapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.networkDetails?.interfaceName, "en1")
        XCTAssertEqual(decoded.networkDetails?.wifiRSSI, -47)
        XCTAssertEqual(decoded.networkDetails?.linkSpeedMbps, 864)
        XCTAssertEqual(decoded.networkDetails?.connectivityStatus, true)
        XCTAssertEqual(decoded.networkDetails?.latencyMs, 14.7)
        XCTAssertEqual(decoded.networkDetails?.jitterMs, 1.2)
        XCTAssertEqual(decoded.networkDetails?.topProcesses?.first?.sentBytesPerSecond, 18_200)
    }

    func testOlderSnapshotWithoutNetworkDetailsDecodes() throws {
        let old = Data(#"{"version":1,"machineName":"Older Mac","timestamp":0,"networkReceivedBytesPerSecond":55.5,"networkSentBytesPerSecond":44.5}"#.utf8)
        let snapshot = try JSONDecoder().decode(MetricSnapshot.self, from: old)
        XCTAssertEqual(snapshot.networkReceivedBytesPerSecond, 55.5)
        XCTAssertEqual(snapshot.networkSentBytesPerSecond, 44.5)
        XCTAssertNil(snapshot.networkDetails)
        XCTAssertEqual(snapshot.version, MetricSnapshot.protocolVersion)
    }

    func testOptionalNetworkFieldsMayBeMissing() throws {
        let details = NetworkDetails(interfaceName: "en0", isActive: false)
        let snapshot = MetricSnapshot(machineName: "Mac", networkDetails: details)
        let decoded = try JSONDecoder().decode(MetricSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.networkDetails?.interfaceName, "en0")
        XCTAssertEqual(decoded.networkDetails?.isActive, false)
        XCTAssertNil(decoded.networkDetails?.ssid)
        XCTAssertNil(decoded.networkDetails?.latencyMs)
        XCTAssertNil(decoded.networkDetails?.topProcesses)
    }

    func testHistoryKeepsAggregateRatesWithoutNetworkMetadataOrProcesses() throws {
        let massiveName = String(repeating: "Interface details are live only", count: 100)
        let network = NetworkDetails(interfaceName: "en1", displayName: massiveName,
                                     dnsServers: Array(repeating: "2001:db8::aaaa", count: 300),
                                     topProcesses: (1...300).map {
            NetworkProcess(pid: $0, name: massiveName,
                           receivedBytesPerSecond: 1_000, sentBytesPerSecond: 200)
        })
        let first = MetricSnapshot(machineName: "Mac", timestamp: Date(timeIntervalSince1970: 1_000),
                                   networkReceivedBytesPerSecond: 15_000,
                                   networkSentBytesPerSecond: 2_500, networkDetails: network)
        let compact = first.withoutCPUProcesses()
        XCTAssertNil(compact.networkDetails)
        XCTAssertEqual(compact.networkReceivedBytesPerSecond, first.networkReceivedBytesPerSecond)
        XCTAssertEqual(compact.networkSentBytesPerSecond, first.networkSentBytesPerSecond)

        var history = MetricHistoryBuffer()
        for tick in 0..<900 {
            history.append(MetricSnapshot(machineName: first.machineName,
                                          timestamp: Date(timeIntervalSince1970: Double(1_000 + tick * 2)),
                                          networkReceivedBytesPerSecond: 15_000,
                                          networkSentBytesPerSecond: 2_500,
                                          networkDetails: network))
        }
        XCTAssertEqual(history.storedSampleCount, 900)
        XCTAssertEqual(history.snapshots.count, 900)
        XCTAssertNil(history.snapshots.last?.networkDetails)
        XCTAssertEqual(history.snapshots.last?.networkSentBytesPerSecond, 2_500)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(history.snapshots).count + 28, 1_000_000)
    }
}
