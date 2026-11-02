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
    let count: Int
    let averageFraction: Double
    var id: String { kind }
}

/// Compact, Exelban-inspired monitoring adapted to the phone's available width.
private struct CPUDetailView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private let userColor = Color(red: 0.04, green: 0.57, blue: 0.99)
    private let systemColor = Color(red: 0.99, green: 0.30, blue: 0.34)
    private let efficiencyColor = Color(red: 0.07, green: 0.76, blue: 0.77)
    private let performanceColor = Color(red: 0.49, green: 0.38, blue: 0.98)
    private let superColor = Color(red: 1.0, green: 0.52, blue: 0.12)

    private var details: CPUDetails? { store.snapshot?.cpuDetails }
    private var usageFraction: Double? {
        if let usage = validFraction(store.snapshot?.cpuFraction) { return usage }
        guard let user = validFraction(details?.userFraction),
              let system = validFraction(details?.systemFraction) else { return nil }
        return min(1, user + system)
    }
    private var liveFrequencyMHz: Double? {
        guard let mhz = details?.frequencyMHz, mhz.isFinite, mhz > 0 else { return nil }
        return mhz
    }
    private var relativeFrequency: Double? {
        guard let mhz = liveFrequencyMHz else { return nil }
        let fastestActiveGroup = [details?.efficiencyFrequencyMHz,
                                  details?.performanceFrequencyMHz,
                                  details?.superFrequencyMHz]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 > 0 }
            .max()
        guard let fastestActiveGroup else { return nil }
        return min(1, mhz / fastestActiveGroup)
    }

    private var history: [CPUHistoryPoint] {
        let samples = store.history.compactMap { sample -> CPUHistoryPoint? in
            guard let fraction = validFraction(sample.cpuFraction) else { return nil }
            return CPUHistoryPoint(date: sample.timestamp, fraction: fraction)
        }
        // Preserve peaks and troughs while keeping long sessions smooth to scroll.
        let bucketSize = max(1, Int(ceil(Double(samples.count) / 160)))
        guard bucketSize > 1 else { return samples }
        var reduced: [CPUHistoryPoint] = []
        reduced.reserveCapacity(322)
        for start in stride(from: 0, to: samples.count, by: bucketSize) {
            let bucket = samples[start..<min(start + bucketSize, samples.count)]
            guard let low = bucket.min(by: { $0.fraction < $1.fraction }),
                  let high = bucket.max(by: { $0.fraction < $1.fraction }) else { continue }
            if low.date == high.date { reduced.append(low) }
            else if low.date < high.date { reduced.append(contentsOf: [low, high]) }
            else { reduced.append(contentsOf: [high, low]) }
        }
        if let last = samples.last, reduced.last?.date != last.date { reduced.append(last) }
        return reduced
    }

    private var coreGroups: [CPUCoreGroup] {
        guard let cores = details?.perCoreFractions, let types = details?.coreTypes else { return [] }
        return ["efficiency", "performance", "super"].compactMap { kind in
            let values = cores.enumerated().compactMap { index, value -> Double? in
                guard types.indices.contains(index), types[index].lowercased() == kind else { return nil }
                return validFraction(value)
            }
            guard !values.isEmpty else { return nil }
            return CPUCoreGroup(kind: kind, count: values.count,
                                averageFraction: values.reduce(0, +) / Double(values.count))
        }
    }
    private var panelBackground: Color {
        colorScheme == .dark ? Color(white: 0.25) : Color(uiColor: .secondarySystemGroupedBackground)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                gauges
                sectionTitle("Usage history")
                historyChart
                coreActivityStrip
                sectionTitle("Details")
                detailsSection
                sectionTitle("Average load")
                loadSection
                sectionTitle("Frequency")
                frequencySection
                sectionTitle("Top processes")
                processSection
            }
            .padding(.horizontal, 17)
            .padding(.top, 19)
            .padding(.bottom, 24)
            .frame(maxWidth: 540)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("CPU")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var gauges: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "cpu")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(store.selectedDisplayName ?? "Mac")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Circle()
                    .fill(store.selectedReachable ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(store.selectedReachable ? "Connected" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 5) {
                    CPURingGauge(value: usageFraction, user: validFraction(details?.userFraction),
                                 system: validFraction(details?.systemFraction),
                                 primaryColor: userColor, secondaryColor: systemColor,
                                 centralText: MetricFormat.percent(usageFraction),
                                 accessibilityTitle: "CPU usage")
                    Text("CPU usage")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 5) {
                    CPURingGauge(value: relativeFrequency, user: nil, system: nil,
                                 primaryColor: userColor, secondaryColor: systemColor,
                                 centralText: liveFrequencyMHz.map {
                                     ($0 / 1_000).formatted(.number.precision(.fractionLength(2)))
                                 } ?? "—",
                                 accessibilityTitle: "Average active CPU frequency in GHz")
                    Text("Frequency · GHz")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 5)
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
        }
        .padding(.top, 19)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var historyChart: some View {
        let points = history
        if points.count > 1 {
            Chart(points) { point in
                AreaMark(x: .value("Time", point.date),
                         y: .value("CPU percentage", point.fraction * 100))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [userColor.opacity(0.48), userColor.opacity(0.10)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date),
                         y: .value("CPU percentage", point.fraction * 100))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .foregroundStyle(userColor)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.background(userColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .frame(height: 105)
            .accessibilityLabel("CPU usage history")
            .accessibilityValue("\(points.count) historical samples")
        } else {
            VStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title3)
                    .foregroundStyle(userColor.opacity(0.8))
                Text("History appears after two CPU readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 105)
            .background(userColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private var coreActivityStrip: some View {
        if let cores = details?.perCoreFractions, !cores.isEmpty {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(cores.indices, id: \.self) { index in
                            let fraction = validFraction(cores[index]) ?? 0
                            let type = coreType(at: index)
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color(for: type).gradient)
                                    .frame(height: max(fraction > 0 ? 2 : 0,
                                                       (geometry.size.height - 2) * fraction))
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Core \(index + 1), \(type ?? "unknown")")
                            .accessibilityValue(percent(fraction))
                        }
                    }
                }
                .frame(height: 48)
                HStack(spacing: 12) {
                    ForEach(["efficiency", "performance", "super"], id: \.self) { kind in
                        if let group = coreGroups.first(where: { $0.kind == kind }) {
                            HStack(spacing: 4) {
                                Circle().fill(color(for: kind)).frame(width: 7, height: 7)
                                Text("\(shortKind(kind)) \(group.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Spacer(minLength: 1)
                    if let cores = details?.logicalCores {
                        Text("\(cores) cores")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 5)
        } else {
            Text("Individual core readings unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 45)
        }
    }

    private var detailsSection: some View {
        VStack(spacing: 9) {
            metricRow("System", percent(validFraction(details?.systemFraction)), color: systemColor)
            metricRow("User", percent(validFraction(details?.userFraction)), color: userColor)
            metricRow("Idle", percent(validFraction(details?.idleFraction)), color: .gray)
            ForEach(["efficiency", "performance", "super"], id: \.self) { kind in
                if let group = coreGroups.first(where: { $0.kind == kind }) {
                    metricRow("\(kind.capitalized) cores", percent(group.averageFraction), color: color(for: kind))
                }
            }
            metricRow("Uptime", uptime(details?.uptimeSeconds))
            metricRow("Temperature", temperature(details?.temperatureCelsius))
            if let physical = details?.physicalCores, let logical = details?.logicalCores {
                metricRow("Physical / logical cores", "\(physical) / \(logical)")
            }
        }
    }

    private var loadSection: some View {
        VStack(spacing: 9) {
            metricRow("1 minute", number(load(at: 0)))
            metricRow("5 minutes", number(load(at: 1)))
            metricRow("15 minutes", number(load(at: 2)))
        }
    }

    private var frequencySection: some View {
        VStack(spacing: 9) {
            metricRow("All cores", frequency(details?.frequencyMHz))
            if details?.efficiencyCores != nil || details?.efficiencyFrequencyMHz != nil {
                metricRow("Efficiency cores", frequency(details?.efficiencyFrequencyMHz), color: efficiencyColor)
            }
            if details?.performanceCores != nil || details?.performanceFrequencyMHz != nil {
                metricRow("Performance cores", frequency(details?.performanceFrequencyMHz), color: performanceColor)
            }
            if details?.superCores != nil || details?.superFrequencyMHz != nil {
                metricRow("Super cores", frequency(details?.superFrequencyMHz), color: superColor)
            }
            if details?.frequencyMHz == nil {
                Text("Live clock readings depend on your Mac and macOS version.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var processSection: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Process")
                Spacer(minLength: 8)
                Text("CPU usage")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            if let processes = details?.topProcesses, !processes.isEmpty {
                ForEach(Array(processes.filter { $0.usagePercent.isFinite && $0.usagePercent >= 0 }
                    .sorted { $0.usagePercent > $1.usagePercent }.prefix(8))) { process in
                    HStack(spacing: 9) {
                        Image(systemName: "app.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityHidden(true)
                        Text(process.name.isEmpty ? "PID \(process.pid)" : process.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 10)
                        Text(process.usagePercent.formatted(.number.precision(.fractionLength(1))) + "%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(process.name), process \(process.pid)")
                    .accessibilityValue("\(process.usagePercent.formatted(.number.precision(.fractionLength(1)))) percent of one core")
                }
            } else {
                Text(details?.topProcesses == nil ? "Per-process readings unavailable" : "No processes reported")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Process percentages can exceed 100% across multiple cores.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    private func metricRow(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack(spacing: 9) {
            if let color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: 10)
            Text(value)
                .foregroundStyle(.primary)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
    private func coreType(at index: Int) -> String? {
        guard let types = details?.coreTypes, types.indices.contains(index) else { return nil }
        let kind = types[index].lowercased()
        return ["efficiency", "performance", "super"].contains(kind) ? kind : nil
    }
    private func color(for kind: String?) -> Color {
        switch kind {
        case "efficiency": efficiencyColor
        case "performance": performanceColor
        case "super": superColor
        default: .gray
        }
    }
    private func shortKind(_ kind: String) -> String {
        switch kind {
        case "efficiency": "E"
        case "performance": "P"
        case "super": "S"
        default: "?"
        }
    }
    private func validFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(1, value)
    }
    private func percent(_ value: Double?) -> String { MetricFormat.percent(value) }
    private func load(at index: Int) -> Double? {
        guard let values = details?.loadAverages, values.indices.contains(index),
              values[index].isFinite, values[index] >= 0 else { return nil }
        return values[index]
    }
    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
    private func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
    private func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "Unavailable" }
        return celsius.formatted(.number.precision(.fractionLength(1))) + " °C"
    }
    private func frequency(_ mhz: Double?) -> String {
        guard let mhz, mhz.isFinite, mhz > 0 else { return "Unavailable" }
        return mhz.formatted(.number.precision(.fractionLength(0))) + " MHz"
    }
}

private struct CPURingGauge: View {
    let value: Double?
    let user: Double?
    let system: Double?
    let primaryColor: Color
    let secondaryColor: Color
    let centralText: String
    let accessibilityTitle: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.23), lineWidth: 10)
            if let user, let system {
                Circle()
                    .trim(from: 0, to: min(1, user))
                    .stroke(primaryColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: min(1, user), to: min(1, user + system))
                    .stroke(secondaryColor, style: StrokeStyle(lineWidth: 10))
                    .rotationEffect(.degrees(-90))
            } else if let value {
                Circle()
                    .trim(from: 0, to: min(1, value))
                    .stroke(primaryColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(centralText)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 14)
        }
        .frame(width: 106, height: 106)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(centralText)
    }
}
