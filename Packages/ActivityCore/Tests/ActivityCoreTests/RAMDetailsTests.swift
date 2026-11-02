import Foundation
import XCTest
@testable import ActivityCore

final class RAMDetailsTests: XCTestCase {
    func testRAMUsesMemoryUnitsWithoutChangingFileUnits() {
        let sixteenGiB: UInt64 = 16 * 1_024 * 1_024 * 1_024
        XCTAssertEqual(MetricFormat.ramBytes(sixteenGiB), "16 GB")
        XCTAssertNotEqual(MetricFormat.ramBytes(sixteenGiB), MetricFormat.bytes(sixteenGiB))
        XCTAssertEqual(MetricFormat.ramBytes(nil), "—")
    }

    func testRAMSnapshotRoundTripPreservesCompositionAndTopProcesses() throws {
        let details = RAMDetails(
            appBytes: 7_000, wiredBytes: 2_000, compressedBytes: 1_000,
            freeBytes: 6_000, cacheBytes: 300, activeBytes: 6_800,
            inactiveBytes: 2_500, swapTotalBytes: 8_000,
            swapUsedBytes: 3_000, swapFreeBytes: 5_000,
            pressureLevel: "warning", swapIns: 40, swapOuts: 10,
            topProcesses: [RAMProcess(pid: 122, name: "WindowServer", residentBytes: 2_500),
                           RAMProcess(pid: 311, name: "Chat On Steroids", residentBytes: 1_800)]
        )
        let snapshot = MetricSnapshot(machineName: "Mac", memoryUsedBytes: 10_000,
                                      memoryTotalBytes: 16_000, ramDetails: details)
        let decoded = try JSONDecoder().decode(MetricSnapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.ramDetails?.appBytes, 7_000)
        XCTAssertEqual(decoded.ramDetails?.pressureLevel, "warning")
        XCTAssertEqual(decoded.ramDetails?.swapUsedBytes, 3_000)
        XCTAssertEqual(decoded.ramDetails?.topProcesses?.first?.residentBytes, 2_500)
    }

    func testHistoryStripsBothCPUProcessesAndRAMDetailsWhileKeepingAggregates() {
        let cpu = CPUDetails(userFraction: 0.2,
                             topProcesses: [CPUProcess(pid: 9, name: "CPU Task", usagePercent: 23)])
        let ram = RAMDetails(appBytes: 5_000, wiredBytes: 2_000,
                             compressedBytes: 1_000, freeBytes: 8_000,
                             swapUsedBytes: 500, pressureLevel: "normal",
                             topProcesses: [RAMProcess(pid: 10, name: "RAM Task", residentBytes: 900)])
        let snapshot = MetricSnapshot(machineName: "Mac", cpuFraction: 0.2,
                                      memoryUsedBytes: 8_000, memoryTotalBytes: 16_000,
                                      cpuDetails: cpu, ramDetails: ram)

        let history = snapshot.withoutCPUProcesses()
        XCTAssertNil(history.cpuDetails?.topProcesses)
        XCTAssertNil(history.ramDetails)
        XCTAssertEqual(history.cpuDetails?.userFraction, 0.2)
        XCTAssertEqual(history.memoryUsedBytes, snapshot.memoryUsedBytes)
        XCTAssertEqual(history.memoryTotalBytes, snapshot.memoryTotalBytes)
    }

    func testOldSnapshotJSONWithoutRAMDetailsDecodes() throws {
        // This shape is received from companions predating the RAM detail API.
        let oldJSON = Data(#"{"version":1,"machineName":"Older Companion","timestamp":0,"cpuFraction":0.25,"memoryUsedBytes":8000,"memoryTotalBytes":16000}"#.utf8)
        let decoded = try JSONDecoder().decode(MetricSnapshot.self, from: oldJSON)
        XCTAssertEqual(decoded.machineName, "Older Companion")
        XCTAssertEqual(decoded.memoryUsedBytes, 8_000)
        XCTAssertEqual(decoded.memoryTotalBytes, 16_000)
        XCTAssertNil(decoded.ramDetails)
        XCTAssertNil(decoded.cpuDetails)
    }
}
