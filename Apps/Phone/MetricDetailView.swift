import ActivityCore
import Charts
import SwiftUI

enum MetricKind {
    case cpu, memory, storage, network

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .network: "network"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .orange
        case .memory: .purple
        case .storage: .blue
        case .network: .green
        }
    }

    var chartUnit: String {
        switch self {
        case .cpu, .storage: "%"
        case .memory: "GB"
        case .network: "MB/s"
        }
    }
}

private struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    let series: String
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

struct MetricDetailView: View {
    let kind: MetricKind
    @ObservedObject var store: NearbyMacStore

    private var latest: MetricSnapshot {
        store.snapshot ?? MetricSnapshot(machineName: store.selectedDisplayName ?? "Mac")
    }
    private var isAwaitingReading: Bool { store.snapshot == nil }

    private var points: [ChartPoint] {
        store.history.flatMap { sample -> [ChartPoint] in
            switch kind {
            case .cpu:
                return sample.cpuFraction.map { [ChartPoint(date: sample.timestamp, value: $0 * 100, series: "CPU")] } ?? []
            case .memory:
                return sample.memoryUsedBytes.map {
                    [ChartPoint(date: sample.timestamp, value: Double($0) / 1_000_000_000, series: "Memory")]
                } ?? []
            case .storage:
                guard let free = sample.diskFreeBytes, let total = sample.diskTotalBytes, total > 0 else { return [] }
                return [ChartPoint(date: sample.timestamp, value: (1 - Double(free) / Double(total)) * 100, series: "Used")]
            case .network:
                var result: [ChartPoint] = []
                if let down = sample.networkReceivedBytesPerSecond {
                    result.append(ChartPoint(date: sample.timestamp, value: down / 1_000_000, series: "Download"))
                }
                if let up = sample.networkSentBytesPerSecond {
                    result.append(ChartPoint(date: sample.timestamp, value: up / 1_000_000, series: "Upload"))
                }
                return result
            }
        }
    }

    private var axisMaximum: Double {
        switch kind {
        case .cpu, .storage: 100
        case .memory: max(1, Double(latest.memoryTotalBytes ?? 0) / 1_000_000_000,
                          (points.map(\.value).max() ?? 0) * 1.1)
        case .network: max(0.1, (points.map(\.value).max() ?? 0) * 1.2)
        }
    }

    var body: some View {
        if kind == .cpu {
            CPUDetailView(store: store)
        } else {
            standardDetail
        }
    }

    private var standardDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(kind.tint)
                            .frame(width: 36, height: 36)
                            .background(kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.subheadline.weight(.semibold))
                            Text(store.selectedDisplayName ?? "Mac")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(primaryValue)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                    Text(secondaryValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .statsCardBackground()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Recent activity")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text(kind.chartUnit).font(.caption).foregroundStyle(.secondary)
                    }
                    if Set(points.map(\.date)).count >= 2 {
                        Chart(points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value(kind.chartUnit, point.value),
                                series: .value("Metric", point.series)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(point.series == "Upload" ? Color.teal : kind.tint)
                        }
                        .chartYScale(domain: 0...axisMaximum)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) {
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.hour().minute())
                            }
                        }
                        .chartLegend(.hidden)
                        .frame(height: 220)
                        .accessibilityLabel("\(kind.title) readings from the last 30 minutes")
                        if kind == .network {
                            HStack(spacing: 18) {
                                chartKey("Download", color: kind.tint)
                                chartKey("Upload", color: .teal)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Waiting for readings",
                            systemImage: "chart.xyaxis.line",
                            description: Text("The graph appears after two readings arrive from your Mac.")
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
                .statsCardBackground()

                VStack(spacing: 12) {
                    switch kind {
                    case .cpu:
                        row("Processor load", MetricFormat.percent(latest.cpuFraction))
                    case .memory:
                        row("Used", MetricFormat.bytes(latest.memoryUsedBytes))
                        row("Physical memory", MetricFormat.bytes(latest.memoryTotalBytes))
                    case .storage:
                        row("Free", MetricFormat.bytes(latest.diskFreeBytes))
                        row("Startup volume capacity", MetricFormat.bytes(latest.diskTotalBytes))
                    case .network:
                        row("Download", MetricFormat.rate(latest.networkReceivedBytesPerSecond))
                        row("Upload", MetricFormat.rate(latest.networkSentBytesPerSecond))
                    }
                    Divider()
                    if let reading = store.snapshot?.timestamp {
                        row("Last reading", reading.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        row("Last reading", "Waiting for Mac")
                    }
                }
                .padding(20)
                .statsCardBackground()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var primaryValue: String {
        switch kind {
        case .cpu: MetricFormat.percent(latest.cpuFraction)
        case .memory: MetricFormat.bytes(latest.memoryUsedBytes)
        case .storage: MetricFormat.bytes(latest.diskFreeBytes)
        case .network: MetricFormat.rate(latest.networkReceivedBytesPerSecond)
        }
    }

    private var secondaryValue: String {
        if isAwaitingReading { return "Waiting for your Mac to send readings" }
        return switch kind {
        case .cpu: "Total processor usage"
        case .memory: "Memory currently in use"
        case .storage: "Free on the startup volume"
        case .network: "Download rate · upload \(MetricFormat.rate(latest.networkSentBytesPerSecond))"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func chartKey(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CPUHistoryPoint: Identifiable {
    let date: Date
    let fraction: Double

    var id: Date { date }
}

private struct CPUCoreGroup: Identifiable {
    let kind: String
    let title: String
    let count: Int
    let averageFraction: Double

    var id: String { kind }
}

/// CPU details use the same cards as the rest of the iPhone dashboard, with
/// Exelban Stats' usage, per-core, load average and process groupings.
private struct CPUDetailView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let userColor = Color.orange
    private let systemColor = Color.pink
    private let idleColor = Color.gray

    private var details: CPUDetails? { store.snapshot?.cpuDetails }

    private var usageFraction: Double? {
        if let overall = validFraction(store.snapshot?.cpuFraction) { return overall }
        guard let user = validFraction(details?.userFraction),
              let system = validFraction(details?.systemFraction) else { return nil }
        return min(1, user + system)
    }

    private var history: [CPUHistoryPoint] {
        let samples = store.history.compactMap { sample -> CPUHistoryPoint? in
            guard let fraction = validFraction(sample.cpuFraction) else { return nil }
            return CPUHistoryPoint(date: sample.timestamp, fraction: fraction)
        }

        // Keep the history graph responsive during long sessions while retaining
        // peaks and troughs that a simple every-Nth downsample would discard.
        let bucketSize = max(1, Int(ceil(Double(samples.count) / 180)))
        guard bucketSize > 1 else { return samples }
        var reduced: [CPUHistoryPoint] = []
        reduced.reserveCapacity(362)
        for start in stride(from: 0, to: samples.count, by: bucketSize) {
            let end = min(start + bucketSize, samples.count)
            let bucket = samples[start..<end]
            guard let low = bucket.min(by: { $0.fraction < $1.fraction }),
                  let high = bucket.max(by: { $0.fraction < $1.fraction }) else { continue }
            if low.date == high.date {
                reduced.append(low)
            } else if low.date < high.date {
                reduced.append(contentsOf: [low, high])
            } else {
                reduced.append(contentsOf: [high, low])
            }
        }
        if let last = samples.last, reduced.last?.date != last.date { reduced.append(last) }
        return reduced
    }

    private var coreGroups: [CPUCoreGroup] {
        guard let cores = details?.perCoreFractions, let types = details?.coreTypes else { return [] }
        return ["efficiency", "performance", "super"].compactMap { kind in
            let fractions = cores.enumerated().compactMap { index, value -> Double? in
                guard types.indices.contains(index), types[index].lowercased() == kind else { return nil }
                return validFraction(value)
            }
            guard !fractions.isEmpty else { return nil }
            let title: String = switch kind {
            case "efficiency": "Efficiency"
            case "performance": "Performance"
            default: "Super"
            }
            return CPUCoreGroup(kind: kind, title: title, count: fractions.count,
                                averageFraction: fractions.reduce(0, +) / Double(fractions.count))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                usageCard
                historyCard
                perCoreCard
                loadAverageCard
                hardwareCard
                processesCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("CPU")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(userColor)
                    .frame(width: 36, height: 36)
                    .background(userColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Processor usage")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(store.selectedDisplayName ?? "Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    usageGauge
                    breakdownRows
                        .frame(minWidth: 116, alignment: .leading)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: 16) {
                    usageGauge
                    breakdownRows
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
            if let timestamp = store.snapshot?.timestamp {
                LabeledContent("Last reading", value: timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for your Mac to send CPU readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .statsCardBackground()
    }

    private var usageGauge: some View {
        CPUUsageGauge(
            total: usageFraction,
            user: validFraction(details?.userFraction),
            system: validFraction(details?.systemFraction),
            userColor: userColor,
            systemColor: systemColor
        )
        .frame(width: 148, height: 148)
    }

    private var breakdownRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage breakdown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            breakdownRow("User", fraction: details?.userFraction, color: userColor)
            breakdownRow("System", fraction: details?.systemFraction, color: systemColor)
            breakdownRow("Idle", fraction: details?.idleFraction, color: idleColor)
        }
    }

    private func breakdownRow(_ title: String, fraction: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(percent(validFraction(fraction)))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var historyCard: some View {
        let points = history
        return VStack(alignment: .leading, spacing: 14) {
            cardHeading("Usage history", detail: "CPU %")
            if Set(points.map(\.date)).count >= 2 {
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("CPU usage", point.fraction * 100)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(userColor.opacity(0.12))

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("CPU usage", point.fraction * 100)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(userColor)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 190)
                .accessibilityLabel("CPU usage history, percentage over time")
            } else {
                unavailable("The history graph appears after two CPU readings arrive from your Mac.")
            }
        }
        .padding(20)
        .statsCardBackground()
    }

    private var perCoreCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeading("Individual cores", detail: details?.logicalCores.map { "\($0) logical" })

            if let cores = details?.perCoreFractions, !cores.isEmpty {
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                          ? [GridItem(.flexible())]
                          : [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    ForEach(cores.indices, id: \.self) { index in
                        coreTile(number: index + 1, value: cores[index], type: coreType(at: index))
                    }
                }

                if !coreGroups.isEmpty {
                    Divider()
                    Text("By core type")
                        .font(.subheadline.weight(.semibold))
                    VStack(spacing: 12) {
                        ForEach(coreGroups) { group in
                            VStack(spacing: 7) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(color(for: group.kind))
                                        .frame(width: 9, height: 9)
                                        .accessibilityHidden(true)
                                    Text("\(group.title) · \(group.count) cores")
                                        .font(.subheadline)
                                    Spacer(minLength: 8)
                                    Text(percent(group.averageFraction))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                }
                                ProgressView(value: group.averageFraction)
                                    .tint(color(for: group.kind))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else {
                unavailable("Per-core usage is unavailable from this Mac.")
            }
        }
        .padding(20)
        .statsCardBackground()
    }

    private func coreTile(number: Int, value: Double, type: String?) -> some View {
        let fraction = validFraction(value)
        let color = color(for: type)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Core \(number)")
                        .font(.subheadline.weight(.medium))
                    if let type {
                        Text(coreTypeLabel(type))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 2)
                Text(percent(fraction))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .tint(color)
            } else {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 4)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core \(number)\(type.map { ", \($0)" } ?? ""), usage")
        .accessibilityValue(percent(fraction))
    }

    private func color(for type: String?) -> Color {
        switch type {
        case "efficiency": .teal
        case "performance": .indigo
        case "super": .orange
        default: .gray
        }
    }

    private func coreType(at index: Int) -> String? {
        guard let types = details?.coreTypes, types.indices.contains(index) else { return nil }
        let value = types[index].lowercased()
        return ["efficiency", "performance", "super"].contains(value) ? value : "unknown"
    }

    private func coreTypeLabel(_ type: String) -> String {
        switch type {
        case "efficiency": "Efficiency"
        case "performance": "Performance"
        case "super": "Super"
        default: "Unknown"
        }
    }

    private var loadAverageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeading("Average load")
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                      ? [GridItem(.flexible())]
                      : Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                loadAverageTile("1 min", index: 0)
                loadAverageTile("5 min", index: 1)
                loadAverageTile("15 min", index: 2)
            }
            Text("Average system load over each interval, not a percentage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .statsCardBackground()
    }

    private func loadAverageTile(_ label: String, index: Int) -> some View {
        let loads = details?.loadAverages ?? []
        let load = loads.indices.contains(index) ? loads[index] : nil

        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(number(load))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading("Processor details")
            LabeledContent("Physical cores", value: count(details?.physicalCores))
            LabeledContent("Logical cores", value: count(details?.logicalCores))
            LabeledContent("Efficiency cores", value: count(details?.efficiencyCores))
            LabeledContent("Performance cores", value: count(details?.performanceCores))
            if let superCores = details?.superCores {
                LabeledContent("Super cores", value: count(superCores))
            }
            Divider()
            LabeledContent("Uptime", value: uptime(details?.uptimeSeconds))
            LabeledContent("Temperature", value: temperature(details?.temperatureCelsius))
            LabeledContent("Frequency", value: frequency(details?.frequencyMHz))
            if hasFrequency(details?.efficiencyFrequencyMHz) {
                LabeledContent("Efficiency frequency", value: frequency(details?.efficiencyFrequencyMHz))
            }
            if hasFrequency(details?.performanceFrequencyMHz) {
                LabeledContent("Performance frequency", value: frequency(details?.performanceFrequencyMHz))
            }
            if hasFrequency(details?.superFrequencyMHz) {
                LabeledContent("Super frequency", value: frequency(details?.superFrequencyMHz))
            }
            if details?.temperatureCelsius == nil || !hasFrequency(details?.frequencyMHz) {
                Text("Temperature and frequency are shown only when macOS provides a reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .statsCardBackground()
    }

    private var processesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeading("Top processes", detail: "CPU %")
            if let processes = details?.topProcesses, !processes.isEmpty {
                let sorted = processes.filter { $0.usagePercent.isFinite && $0.usagePercent >= 0 }
                    .sorted { $0.usagePercent > $1.usagePercent }
                if sorted.isEmpty {
                    unavailable("Process usage readings are unavailable.")
                } else {
                    ForEach(Array(sorted.prefix(8)), id: \.pid) { process in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name.isEmpty ? "Process \(process.pid)" : process.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text("PID \(process.pid)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(process.usagePercent.formatted(.number.precision(.fractionLength(1))) + "%")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        if process.pid != sorted.prefix(8).last?.pid { Divider() }
                    }
                }
                Text("A process can use more than 100% CPU when it runs on multiple cores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                unavailable(details?.topProcesses == nil
                            ? "Per-process CPU usage is unavailable from this Mac."
                            : "No process readings have arrived yet.")
            }
        }
        .padding(20)
        .statsCardBackground()
    }

    private func cardHeading(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    private func validFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(1, value)
    }

    private func percent(_ fraction: Double?) -> String {
        MetricFormat.percent(fraction)
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2)))
    }

    private func count(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "—" }
        return value.formatted()
    }

    private func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }

    private func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "Unavailable" }
        return celsius.formatted(.number.precision(.fractionLength(1))) + " °C"
    }

    private func frequency(_ mhz: Double?) -> String {
        guard hasFrequency(mhz), let mhz else { return "Unavailable" }
        return mhz.formatted(.number.precision(.fractionLength(0))) + " MHz"
    }

    private func hasFrequency(_ mhz: Double?) -> Bool {
        guard let mhz else { return false }
        return mhz.isFinite && mhz > 0
    }
}

private struct CPUUsageGauge: View {
    let total: Double?
    let user: Double?
    let system: Double?
    let userColor: Color
    let systemColor: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 17)

            if let user, let system {
                Circle()
                    .trim(from: 0, to: min(1, user))
                    .stroke(userColor, style: StrokeStyle(lineWidth: 17))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: min(1, user), to: min(1, user + system))
                    .stroke(systemColor, style: StrokeStyle(lineWidth: 17))
                    .rotationEffect(.degrees(-90))
            } else if let total {
                Circle()
                    .trim(from: 0, to: min(1, total))
                    .stroke(userColor, style: StrokeStyle(lineWidth: 17, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 4) {
                Text(MetricFormat.percent(total))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Total CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Total CPU usage")
        .accessibilityValue(MetricFormat.percent(total))
    }
}
