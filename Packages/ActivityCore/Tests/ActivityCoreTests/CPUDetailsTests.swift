import XCTest
@testable import ActivityCore

final class CPUDetailsTests: XCTestCase {
    func testExpandedCPUDataRoundTripsAndProcessHistoryStaysCompact() throws {
        let detail = CPUDetails(userFraction: 0.17, systemFraction: 0.05, idleFraction: 0.78,
                                perCoreFractions: [0.25, 0.31, 0.07],
                                coreTypes: ["efficiency", "performance", "super"],
                                physicalCores: 3, logicalCores: 3,
                                efficiencyCores: 1, performanceCores: 1, superCores: 1,
                                loadAverages: [1.3, 1.1, 0.9], uptimeSeconds: 5400,
                                temperatureCelsius: 67.4, frequencyMHz: 2_950,
                                efficiencyFrequencyMHz: 2_240,
                                performanceFrequencyMHz: 4_300,
                                superFrequencyMHz: 4_520,
                                topProcesses: [CPUProcess(pid: 301, name: "WindowServer", usagePercent: 128.5)])
        let sample = MetricSnapshot(machineName: "Mac", cpuFraction: 0.22, cpuDetails: detail)
        let restored = try JSONDecoder().decode(MetricSnapshot.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(restored, sample)
        XCTAssertEqual(restored.cpuDetails?.topProcesses?.first?.usagePercent, 128.5)

        let historical = sample.withoutCPUProcesses()
        XCTAssertNil(historical.cpuDetails?.topProcesses)
        XCTAssertEqual(historical.cpuDetails?.perCoreFractions, [0.25, 0.31, 0.07])
        XCTAssertEqual(historical.cpuDetails?.superFrequencyMHz, 4_520)
        XCTAssertEqual(historical.cpuFraction, sample.cpuFraction)
    }

    func testLegacySnapshotWithoutCPUDetailsStillDecodes() throws {
        let original = MetricSnapshot(machineName: "Older Companion", cpuFraction: 0.45)
        let json = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNil(object["cpuDetails"])
        let restored = try JSONDecoder().decode(MetricSnapshot.self, from: json)
        XCTAssertEqual(restored.cpuFraction, 0.45)
        XCTAssertNil(restored.cpuDetails)
        XCTAssertEqual(restored.version, MetricSnapshot.protocolVersion)
    }
}
