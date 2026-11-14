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
        } else if kind == .memory {
            RAMDetailView(store: store)
        } else if kind == .storage {
            DiskDetailView(store: store)
        } else if kind == .network {
            NetworkDetailView(store: store)
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
                        row("Used", MetricFormat.ramBytes(latest.memoryUsedBytes))
                        row("Physical memory", MetricFormat.ramBytes(latest.memoryTotalBytes))
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
        case .memory: MetricFormat.ramBytes(latest.memoryUsedBytes)
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

/// Compact CPU monitoring designed for the available iPhone width.
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

private struct RAMHistoryPoint: Identifiable {
    let date: Date
    let fraction: Double
    var id: Date { date }
}

private struct RAMSlice: Identifiable {
    let name: String
    let start: Double
    let end: Double
    let color: Color
    var id: String { name }
}

/// Compact RAM detail view with live pressure, composition and process readings.
private struct RAMDetailView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private let appColor = Color(red: 0.04, green: 0.57, blue: 0.99)
    private let wiredColor = Color(red: 1.0, green: 0.57, blue: 0.14)
    private let compressedColor = Color(red: 0.96, green: 0.31, blue: 0.49)
    private let freeColor = Color.gray.opacity(0.48)

    private var details: RAMDetails? { store.snapshot?.ramDetails }
    private var total: UInt64? {
        guard let value = store.snapshot?.memoryTotalBytes, value > 0 else { return nil }
        return value
    }
    private var used: UInt64? {
        guard let value = store.snapshot?.memoryUsedBytes,
              let total, value <= total else { return nil }
        return value
    }
    private var usedFraction: Double? {
        guard let used, let total else { return nil }
        return Double(used) / Double(total)
    }
    private var pressure: String? {
        guard let value = details?.pressureLevel?.lowercased(),
              ["normal", "warning", "critical"].contains(value) else { return nil }
        return value
    }
    private var panelBackground: Color {
        colorScheme == .dark ? Color(white: 0.25) : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var composition: [RAMSlice]? {
        guard let total,
              let app = details?.appBytes, let wired = details?.wiredBytes,
              let compressed = details?.compressedBytes,
              let free = details?.freeBytes else { return nil }
        let capacity = Double(total)
        let appShare = Double(app) / capacity
        let wiredShare = Double(wired) / capacity
        let compressedShare = Double(compressed) / capacity
        let sum = appShare + wiredShare + compressedShare
        // Segments represent real supplied categories only; reject inconsistent readings.
        guard sum <= 1.0001,
              let usedFraction, abs(sum - usedFraction) <= 0.05,
              abs(sum + Double(free) / capacity - 1) <= 0.05 else { return nil }
        return [
            RAMSlice(name: "App", start: 0, end: appShare, color: appColor),
            RAMSlice(name: "Wired", start: appShare, end: appShare + wiredShare, color: wiredColor),
            RAMSlice(name: "Compressed", start: appShare + wiredShare, end: sum, color: compressedColor)
        ]
    }

    private var history: [RAMHistoryPoint] {
        let samples = store.history.compactMap { sample -> RAMHistoryPoint? in
            guard let used = sample.memoryUsedBytes,
                  let total = sample.memoryTotalBytes, total > 0, used <= total else { return nil }
            return RAMHistoryPoint(date: sample.timestamp, fraction: Double(used) / Double(total))
        }
        let bucketSize = max(1, Int(ceil(Double(samples.count) / 160)))
        guard bucketSize > 1 else { return samples }
        var result: [RAMHistoryPoint] = []
        result.reserveCapacity(322)
        for start in stride(from: 0, to: samples.count, by: bucketSize) {
            let bucket = samples[start..<min(start + bucketSize, samples.count)]
            guard let low = bucket.min(by: { $0.fraction < $1.fraction }),
                  let high = bucket.max(by: { $0.fraction < $1.fraction }) else { continue }
            if low.date == high.date { result.append(low) }
            else if low.date < high.date { result.append(contentsOf: [low, high]) }
            else { result.append(contentsOf: [high, low]) }
        }
        if let last = samples.last, result.last?.date != last.date { result.append(last) }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                dashboard
                sectionTitle("Usage history")
                historyChart
                sectionTitle("Details")
                breakdown
                sectionTitle("Top processes")
                processes
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
        .navigationTitle("RAM")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dashboard: some View {
        VStack(spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "memorychip")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(store.selectedDisplayName ?? "Mac")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Circle()
                    .fill(store.selectedReachable ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(store.selectedReachable ? "Connected" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 4) {
                    RAMPressureGauge(status: pressure)
                        .frame(height: 106, alignment: .bottom)
                    Text("Memory pressure")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    RAMUsageRing(usedFraction: usedFraction,
                                 slices: composition,
                                 appColor: appColor,
                                 centralText: MetricFormat.percent(usedFraction))
                    Text("Memory usage")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 5)
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
            Text(title.uppercased())
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
                         y: .value("Memory percentage", point.fraction * 100))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [appColor.opacity(0.48), appColor.opacity(0.10)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date),
                         y: .value("Memory percentage", point.fraction * 100))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .foregroundStyle(appColor)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.background(appColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .frame(height: 105)
            .accessibilityLabel("Memory usage history")
            .accessibilityValue("\(points.count) samples, latest \(MetricFormat.percent(points.last?.fraction))")
        } else {
            VStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title3)
                    .foregroundStyle(appColor.opacity(0.8))
                Text("History appears after two memory readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 105)
            .background(appColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var breakdown: some View {
        VStack(spacing: 9) {
            metricRow("Used", MetricFormat.ramBytes(used))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(freeColor)
                    if let slices = composition {
                        ForEach(slices) { slice in
                            Rectangle()
                                .fill(slice.color)
                                .frame(width: max(0, geometry.size.width * (slice.end - slice.start)))
                                .offset(x: geometry.size.width * slice.start)
                        }
                    } else if let usedFraction {
                        Rectangle()
                            .fill(appColor)
                            .frame(width: geometry.size.width * usedFraction)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory composition")
            .accessibilityValue(composition == nil ? "Detailed breakdown unavailable" : "App, wired, compressed, and free memory")
            metricRow("App", MetricFormat.ramBytes(details?.appBytes), color: appColor)
            metricRow("Wired", MetricFormat.ramBytes(details?.wiredBytes), color: wiredColor)
            metricRow("Compressed", MetricFormat.ramBytes(details?.compressedBytes), color: compressedColor)
            metricRow("Free", MetricFormat.ramBytes(details?.freeBytes), color: freeColor)
            metricRow("Swap", MetricFormat.ramBytes(details?.swapUsedBytes))
            if let total {
                Text("\(MetricFormat.ramBytes(total)) physical memory")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
            }
        }
    }

    private var processes: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Process")
                Spacer(minLength: 8)
                Text("Memory")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            if let reported = details?.topProcesses {
                let ranked = Array(reported.sorted { $0.residentBytes > $1.residentBytes }.prefix(8))
                if ranked.isEmpty {
                    Text("No processes reported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(ranked) { process in
                        HStack(spacing: 9) {
                            Image(systemName: "app.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.secondary.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 5))
                                .accessibilityHidden(true)
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(process.name.isEmpty ? "PID \(process.pid)" : process.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(MetricFormat.ramBytes(process.residentBytes))
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(process.name.isEmpty ? "PID \(process.pid)" : process.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 10)
                                Text(MetricFormat.ramBytes(process.residentBytes))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(process.name.isEmpty ? "Process" : process.name), process \(process.pid)")
                        .accessibilityValue("\(MetricFormat.ramBytes(process.residentBytes)) memory")
                    }
                }
            } else {
                Text("Per-process memory readings unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: 10)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// A fixed, three-zone semicircle with an indicator on the reported pressure state.
private struct RAMPressureGauge: View {
    let status: String?

    private let ranges: [(start: Double, end: Double, color: Color)] = [
        (0, 0.315, .green),
        (0.343, 0.657, .yellow),
        (0.685, 1, .red)
    ]

    private var indicator: Double? {
        switch status {
        case "normal": 1.0 / 6
        case "warning": 0.5
        case "critical": 5.0 / 6
        default: nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(0..<ranges.count, id: \.self) { index in
                RAMArcShape(start: ranges[index].start, end: ranges[index].end)
                    .stroke(ranges[index].color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            }
            if let indicator {
                RAMPressureNeedle(position: indicator)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            }
            Text(status?.capitalized ?? "—")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 118, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory pressure")
        .accessibilityValue(status?.capitalized ?? "Unavailable")
    }
}

private struct RAMArcShape: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let radius = min((rect.width - 12) / 2, rect.height - 24)
        let center = CGPoint(x: rect.midX, y: rect.maxY - 18)
        let steps = 30
        var path = Path()
        for index in 0...steps {
            let fraction = start + (end - start) * Double(index) / Double(steps)
            let angle = Double.pi * (1 + fraction)
            let point = CGPoint(x: center.x + radius * cos(angle),
                                y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        return path
    }
}

private struct RAMPressureNeedle: Shape {
    let position: Double

    func path(in rect: CGRect) -> Path {
        let radius = min((rect.width - 12) / 2, rect.height - 24) - 9
        let center = CGPoint(x: rect.midX, y: rect.maxY - 18)
        let angle = Double.pi * (1 + position)
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x + radius * cos(angle),
                                 y: center.y + radius * sin(angle)))
        return path
    }
}

private struct RAMUsageRing: View {
    let usedFraction: Double?
    let slices: [RAMSlice]?
    let appColor: Color
    let centralText: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.35), lineWidth: 10)
            if let slices {
                ForEach(slices) { slice in
                    Circle()
                        .trim(from: slice.start, to: slice.end)
                        .stroke(slice.color, lineWidth: 10)
                        .rotationEffect(.degrees(-90))
                }
            } else if let usedFraction {
                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(appColor, lineWidth: 10)
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
        .accessibilityLabel("Memory usage")
        .accessibilityValue(centralText)
    }
}

private struct DiskIOPoint: Identifiable {
    let timestamp: Date
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    var id: Date { timestamp }

    init?(timestamp: Date, read: Double?, write: Double?) {
        let validRead = read.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let validWrite = write.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard validRead != nil || validWrite != nil else { return nil }
        self.timestamp = timestamp
        readBytesPerSecond = validRead
        writeBytesPerSecond = validWrite
    }
}

/// One card per mounted volume; historical I/O is matched by stable volume ID.
private struct DiskDetailView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("Stats.showRemovableDisks") private var showRemovableDisks = false
    @AppStorage(DiskDisplayPreference.selectedDiskKey) private var selectedDiskID = ""
    @AppStorage(DiskDisplayPreference.processCountKey) private var processCount = 5
    @AppStorage(DiskDisplayPreference.showSpeedKey) private var showDiskSpeed = false
    @AppStorage(DiskDisplayPreference.showTextKey) private var showDiskText = false
    @AppStorage(DiskDisplayPreference.speedBaseKey) private var speedBase = "byte"
    @AppStorage(DiskDisplayPreference.speedUnitKey) private var speedUnit = "auto"
    @AppStorage(DiskDisplayPreference.textTemplateKey) private var textTemplate = "$capacity.free/$capacity.total"
    @AppStorage(NearbyMacStore.diskUpdateIntervalKey) private var diskUpdateInterval = 10
    @AppStorage(NearbyMacStore.diskSMARTKey) private var smartEnabled = true
    @AppStorage(NearbyMacStore.diskSMARTIntervalKey) private var smartInterval = 30
    @AppStorage(NearbyMacStore.diskATASMARTKey) private var ataSMARTEnabled = false
    @State private var capturedHistory: [String: [DiskIOPoint]] = [:]
    @State private var showingSettings = false

    private let readColor = Color(red: 0.06, green: 0.56, blue: 0.98)
    private let writeColor = Color(red: 0.97, green: 0.31, blue: 0.36)

    private var panelColor: Color {
        colorScheme == .dark ? Color(white: 0.25) : Color(uiColor: .secondarySystemGroupedBackground)
    }
    private var volumes: [DiskVolume] {
        (store.snapshot?.diskDetails?.volumes ?? []).filter { showRemovableDisks || $0.isRemovable != true }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(store.selectedDisplayName ?? "Mac")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Circle()
                        .fill(store.selectedReachable ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(store.selectedReachable ? "Connected" : "Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                if !volumes.isEmpty {
                    ForEach(volumes, id: \.id) { volume in
                        DiskVolumeCard(volume: volume,
                                       history: history(for: volume.id),
                                       background: panelColor,
                                       readColor: readColor, speedBase: speedBase, speedUnit: speedUnit,
                                       writeColor: writeColor)
                    }
                } else if let snapshot = store.snapshot,
                          snapshot.diskTotalBytes != nil || snapshot.diskFreeBytes != nil {
                    DiskVolumeCard(volume: nil,
                                   legacyTotal: snapshot.diskTotalBytes,
                                   legacyFree: snapshot.diskFreeBytes,
                                   history: [], background: panelColor,
                                   readColor: readColor, speedBase: speedBase,
                                   speedUnit: speedUnit, writeColor: writeColor)
                } else {
                    ContentUnavailableView(
                        "Waiting for disk readings",
                        systemImage: "internaldrive",
                        description: Text("Disk information appears after a reading arrives from your Mac.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(15)
                    .background(panelColor, in: RoundedRectangle(cornerRadius: 18))
                }

                if processCount > 0 { processCard }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Disk")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Disk settings")
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Section {
                        Picker("Update interval", selection: $diskUpdateInterval) {
                            ForEach(DiskSamplingSettings.intervals, id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(seconds)
                            }
                        }
                        Picker("Number of top processes", selection: $processCount) {
                            ForEach([0, 3, 5, 8, 10, 15], id: \.self) { count in
                                Text(count == 0 ? "Off" : "\(count)").tag(count)
                            }
                        }
                    } header: {
                        Text("Reading")
                    } footer: {
                        Text("Sampling settings apply to the connected Mac. The dashboard updates every 2 seconds.")
                    }
                    Section {
                        Picker("Disk to show", selection: $selectedDiskID) {
                            Text("Startup disk").tag("")
                            ForEach(volumes.filter { $0.mountPath != "/" }) { volume in
                                Text(volume.name).tag(volume.id)
                            }
                        }
                        Toggle("Show removable disks", isOn: $showRemovableDisks)
                    } header: {
                        Text("Volumes")
                    } footer: {
                        Text("Removable disks include mounted disk images and removable drives. The selected disk is used on the dashboard.")
                    }
                    if showDiskSpeed {
                        Section("Disk read and write speeds") {
                            Picker("Base", selection: $speedBase) {
                                Text("Bytes").tag("byte")
                                Text("Bits").tag("bit")
                            }
                            Picker("Units", selection: $speedUnit) {
                                Text("Auto").tag("auto")
                                Text("KB/Kb").tag("KB")
                                Text("MB/Mb").tag("MB")
                                Text("GB/Gb").tag("GB")
                                Text("TB/Tb").tag("TB")
                            }
                        }
                    }
                    Section {
                        Toggle("SMART", isOn: $smartEnabled)
                        if smartEnabled {
                            Picker("Update interval", selection: $smartInterval) {
                                ForEach(DiskSamplingSettings.intervals.filter { $0 >= diskUpdateInterval }, id: \.self) { seconds in
                                    Text("\(seconds) seconds").tag(seconds)
                                }
                            }
                            Toggle("ATA SMART", isOn: $ataSMARTEnabled)
                        }
                    } header: {
                        Text("SMART")
                    } footer: {
                        Text("SMART refreshes when Disk is sampled, so its interval cannot be shorter than the Disk interval.")
                    }
                    if showDiskText {
                        Section {
                            TextField("Text widget value", text: $textTemplate)
                            Text(DiskDisplayPreference.text(textTemplate,
                                 volume: DiskDisplayPreference.selectedVolume(
                                    in: store.snapshot ?? MetricSnapshot(machineName: "Mac"),
                                    id: selectedDiskID, showRemovable: showRemovableDisks)))
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("Disk text")
                        } footer: {
                            Text("Use $capacity.free, $capacity.used, $capacity.total, $percentage.free, or $percentage.used.")
                        }
                    }
                }
                .navigationTitle("Disk Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingSettings = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: diskUpdateInterval) { _, interval in
            if smartInterval < interval { smartInterval = interval }
            store.syncDiskSamplingSettings()
        }
        .onChange(of: processCount) { _, _ in store.syncDiskSamplingSettings() }
        .onChange(of: smartEnabled) { _, _ in store.syncDiskSamplingSettings() }
        .onChange(of: smartInterval) { _, _ in store.syncDiskSamplingSettings() }
        .onChange(of: ataSMARTEnabled) { _, _ in store.syncDiskSamplingSettings() }
        .onChange(of: showRemovableDisks) { _, visible in
            if !visible,
               store.snapshot?.diskDetails?.volumes.first(where: { $0.id == selectedDiskID })?.isRemovable == true {
                selectedDiskID = ""
            }
        }
        .onAppear { capture(store.snapshot) }
        .onChange(of: store.snapshot) { _, snapshot in capture(snapshot) }
        .onChange(of: store.selectedName) { _, _ in
            capturedHistory.removeAll()
            selectedDiskID = ""
        }
    }

    private func history(for volumeID: String) -> [DiskIOPoint] {
        // History may omit disk details on older companions. Local live sampling
        // still provides an honest short chart while this screen is open.
        let remote = store.history.compactMap { snapshot -> DiskIOPoint? in
            guard let volume = snapshot.diskDetails?.volumes.first(where: { $0.id == volumeID }) else {
                return nil
            }
            return DiskIOPoint(timestamp: snapshot.timestamp,
                               read: volume.readBytesPerSecond,
                               write: volume.writeBytesPerSecond)
        }
        let local = capturedHistory[volumeID] ?? []
        var byTime: [Date: DiskIOPoint] = [:]
        for point in remote { byTime[point.timestamp] = point }
        for point in local { byTime[point.timestamp] = point }
        let samples = byTime.values.sorted { $0.timestamp < $1.timestamp }
        guard samples.count > 180 else { return samples }
        // Keep the first/last and each direction's own peak in every bucket.
        // A large read burst must never cause a smaller write peak to vanish.
        let bucketSize = Int(ceil(Double(samples.count) / 90.0))
        var result: [DiskIOPoint] = []
        result.reserveCapacity(364)
        for start in stride(from: 0, to: samples.count, by: bucketSize) {
            let bucket = samples[start..<min(samples.count, start + bucketSize)]
            let candidates: [DiskIOPoint?] = [
                bucket.first, bucket.last,
                bucket.max { ($0.readBytesPerSecond ?? 0) < ($1.readBytesPerSecond ?? 0) },
                bucket.max { ($0.writeBytesPerSecond ?? 0) < ($1.writeBytesPerSecond ?? 0) }
            ]
            var seen = Set<Date>()
            result.append(contentsOf: candidates.compactMap { $0 }
                .filter { seen.insert($0.timestamp).inserted }
                .sorted { $0.timestamp < $1.timestamp })
        }
        if let last = samples.last, result.last?.timestamp != last.timestamp { result.append(last) }
        return result
    }

    private func capture(_ snapshot: MetricSnapshot?) {
        guard let snapshot else { return }
        for volume in snapshot.diskDetails?.volumes ?? [] {
            guard let point = DiskIOPoint(timestamp: snapshot.timestamp,
                                          read: volume.readBytesPerSecond,
                                          write: volume.writeBytesPerSecond) else { continue }
            var history = capturedHistory[volume.id] ?? []
            if history.last?.timestamp == point.timestamp { history[history.count - 1] = point }
            else { history.append(point) }
            if history.count > 180 { history.removeFirst(history.count - 180) }
            capturedHistory[volume.id] = history
        }
    }

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
                Text("TOP PROCESSES")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
            }
            if dynamicTypeSize.isAccessibilitySize {
                Text("Process · read and write rates")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Process")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Read")
                        .frame(width: 76, alignment: .trailing)
                    Text("Write")
                        .frame(width: 76, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }

            if let reported = store.snapshot?.diskDetails?.topProcesses {
                let ranked = Array(reported.sorted {
                    diskRateValue($0.readBytesPerSecond) + diskRateValue($0.writeBytesPerSecond) >
                    diskRateValue($1.readBytesPerSecond) + diskRateValue($1.writeBytesPerSecond)
                }.prefix(processCount))
                if ranked.isEmpty {
                    Text("No processes reported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ranked, id: \.pid) { process in
                        processRow(process)
                    }
                }
            } else {
                Text("Per-process disk activity unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func processRow(_ process: DiskProcess) -> some View {
        let name = process.name.isEmpty ? "PID \(process.pid)" : process.name
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.medium))
                HStack(spacing: 14) {
                    Text("Read \(diskRate(process.readBytesPerSecond, base: speedBase, unit: speedUnit))")
                        .foregroundStyle(readColor)
                    Text("Write \(diskRate(process.writeBytesPerSecond, base: speedBase, unit: speedUnit))")
                        .foregroundStyle(writeColor)
                }
                .font(.caption)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), process \(process.pid)")
            .accessibilityValue("Read \(diskRate(process.readBytesPerSecond, base: speedBase, unit: speedUnit)), write \(diskRate(process.writeBytesPerSecond, base: speedBase, unit: speedUnit))")
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 19)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityHidden(true)
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(diskRate(process.readBytesPerSecond, base: speedBase, unit: speedUnit))
                    .frame(width: 76, alignment: .trailing)
                    .foregroundStyle(readColor)
                Text(diskRate(process.writeBytesPerSecond, base: speedBase, unit: speedUnit))
                    .frame(width: 76, alignment: .trailing)
                    .foregroundStyle(writeColor)
            }
            .font(.caption)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), process \(process.pid)")
            .accessibilityValue("Read \(diskRate(process.readBytesPerSecond, base: speedBase, unit: speedUnit)), write \(diskRate(process.writeBytesPerSecond, base: speedBase, unit: speedUnit))")
        }
    }
}

private func diskRate(_ bytesPerSecond: Double?, base: String, unit: String) -> String {
    DiskDisplayPreference.rate(bytesPerSecond, base: base, unit: unit)
}

private func diskRateValue(_ bytesPerSecond: Double?) -> Double {
    guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return 0 }
    return bytesPerSecond
}

/// The read and write traces use independent visual scales. A large read spike
/// must not flatten a smaller, genuinely measured write trace (or vice versa).
/// The chart has no numeric Y axis; the adjacent values remain actual B/s.
private func diskChartScale(_ rates: [Double]) -> Double {
    let active = rates.filter { $0.isFinite && $0 > 0 }.sorted()
    guard !active.isEmpty else { return 1 }
    return max(1, active[Int(Double(active.count - 1) * 0.9)])
}

/// Draw each direction in its own half of the plot. Explicit canvas fills
/// avoid Swift Charts combining ungrouped area marks into a single blue series.
private struct DiskActivityPlot: View {
    let history: [DiskIOPoint]
    let readColor: Color
    let writeColor: Color

    var body: some View {
        let readScale = diskChartScale(history.compactMap(\.readBytesPerSecond))
        let writeScale = diskChartScale(history.compactMap(\.writeBytesPerSecond))
        Canvas { context, size in
            guard let first = history.first, let last = history.last,
                  size.width > 0, size.height > 0 else { return }

            let middle = size.height / 2
            let beginning = first.timestamp.timeIntervalSinceReferenceDate
            let duration = max(1, last.timestamp.timeIntervalSinceReferenceDate - beginning)

            // Read activity is blue below the baseline; write activity is red above.
            // Each has its own scale so one busy direction cannot hide the other.
            drawSeries(in: context, size: size, middle: middle,
                       beginning: beginning, duration: duration,
                       scale: readScale, isWrite: false, color: readColor)
            drawSeries(in: context, size: size, middle: middle,
                       beginning: beginning, duration: duration,
                       scale: writeScale, isWrite: true, color: writeColor)

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: middle))
            baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(.secondary.opacity(0.38)), lineWidth: 0.7)
        }
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func drawSeries(in context: GraphicsContext, size: CGSize,
                            middle: CGFloat, beginning: TimeInterval,
                            duration: TimeInterval, scale: Double,
                            isWrite: Bool, color: Color) {
        var points: [CGPoint] = []
        let halfHeight = max(0, middle - 2)

        func drawSegment() {
            guard let first = points.first, let last = points.last else { return }
            var filledArea = Path()
            filledArea.move(to: CGPoint(x: first.x, y: middle))
            for point in points { filledArea.addLine(to: point) }
            filledArea.addLine(to: CGPoint(x: last.x, y: middle))
            filledArea.closeSubpath()
            context.fill(filledArea, with: .color(color.opacity(0.67)))

            var outline = Path()
            outline.move(to: first)
            for point in points.dropFirst() { outline.addLine(to: point) }
            context.stroke(outline, with: .color(color), lineWidth: 1.35)
        }

        for sample in history {
            let rate = isWrite ? sample.writeBytesPerSecond : sample.readBytesPerSecond
            guard let rate, rate.isFinite, rate >= 0 else {
                // Do not bridge periods where the Mac reported no measurement.
                drawSegment()
                points.removeAll(keepingCapacity: true)
                continue
            }
            let x = CGFloat((sample.timestamp.timeIntervalSinceReferenceDate - beginning) / duration)
                * size.width
            let amplitude = CGFloat(min(1, rate / scale)) * halfHeight
            points.append(CGPoint(x: x, y: middle + (isWrite ? -amplitude : amplitude)))
        }
        drawSegment()
    }
}

private struct DiskVolumeCard: View {
    let volume: DiskVolume?
    var legacyTotal: UInt64? = nil
    var legacyFree: UInt64? = nil
    let history: [DiskIOPoint]
    let background: Color
    let readColor: Color
    let speedBase: String
    let speedUnit: String
    let writeColor: Color

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var name: String { volume?.name.isEmpty == false ? (volume?.name ?? "") : "Startup volume" }
    private var total: UInt64? { volume?.totalBytes ?? legacyTotal }
    private var free: UInt64? { volume?.freeBytes ?? legacyFree }
    private var usedFraction: Double? {
        guard let total, let free, total > 0, free <= total else { return nil }
        return 1 - Double(free) / Double(total)
    }
    private var readRate: Double? { volume?.readBytesPerSecond }
    private var writeRate: Double? { volume?.writeBytesPerSecond }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        ioLabel("Read", rate: readRate, color: readColor)
                        ioLabel("Write", rate: writeRate, color: writeColor)
                    }
                    .frame(width: 116, alignment: .leading)
                    activityChart
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        ioLabel("Read", rate: readRate, color: readColor)
                        ioLabel("Write", rate: writeRate, color: writeColor)
                    }
                    activityChart
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18))
                    if let usedFraction {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.gradient)
                            .frame(width: proxy.size.width * usedFraction)
                    }
                }
            }
            .frame(height: 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk capacity used")
            .accessibilityValue(usedFraction.map { MetricFormat.percent($0) } ?? "Unavailable")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(MetricFormat.bytes(free)) of \(MetricFormat.bytes(total)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 1)
                Text(usedFraction.map { MetricFormat.percent(1 - $0) } ?? "—")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 9) {
                detailRow("Total read", MetricFormat.bytes(volume?.totalReadBytes))
                detailRow("Total written", MetricFormat.bytes(volume?.totalWrittenBytes))
                detailRow("File system", volume?.fileSystem.map { $0.uppercased() } ?? "Unavailable")
                detailRow("Connection type", text(volume?.connectionType))
            }
            if let smart = volume?.smart { smartDetails(smart) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ioLabel(_ name: String, rate: Double?, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(name)
                .foregroundStyle(.secondary)
            Text(diskRate(rate, base: speedBase, unit: speedUnit))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var activityChart: some View {
        if history.count >= 2 {
            DiskActivityPlot(history: history, readColor: readColor, writeColor: writeColor)
            .frame(height: 95)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) read and write activity history")
            .accessibilityValue("\(history.count) samples; blue reads below center and red writes above center, independently scaled. Last read \(diskRate(readRate, base: speedBase, unit: speedUnit)), write \(diskRate(writeRate, base: speedBase, unit: speedUnit))")
        } else {
            VStack(spacing: 5) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(readRate == nil && writeRate == nil ? "Disk I/O rates unavailable" :
                        "History appears after two I/O readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 95)
            .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.75)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Unavailable" }
        return value
    }

    @ViewBuilder
    private func smartDetails(_ smart: DiskSMART) -> some View {
        let hasMetrics = smart.totalReadBytes != nil || smart.totalWrittenBytes != nil ||
            smart.temperatureCelsius != nil || smart.healthPercent != nil ||
            smart.powerCycles != nil || smart.powerOnHours != nil ||
            smart.criticalWarning != nil || smart.availableSparePercent != nil
        if hasMetrics {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
                Text("SMART")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(smart.status ?? "Status unavailable")
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
            }
            .padding(.top, 2)
            VStack(spacing: 9) {
                detailRow("Total read", MetricFormat.bytes(smart.totalReadBytes))
                detailRow("Total written", MetricFormat.bytes(smart.totalWrittenBytes))
                detailRow("Temperature", smart.temperatureCelsius.flatMap { value in
                    value.isFinite ? Measurement(value: value, unit: UnitTemperature.celsius)
                        .formatted(.measurement(width: .abbreviated, usage: .weather)) : nil
                } ?? "Unavailable")
                detailRow("Health", smart.healthPercent.map { percent($0) } ?? "Unavailable")
                detailRow("Power cycles", smart.powerCycles?.formatted() ?? "Unavailable")
                detailRow("Power on hours", smart.powerOnHours.map { $0.formatted() + " h" } ?? "Unavailable")
                detailRow("Critical warning", smart.criticalWarning.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable")
                detailRow("Available spare", smart.availableSparePercent.map { percent($0) } ?? "Unavailable")
            }
        } else if let status = smart.status, status != "Not Supported", !status.isEmpty {
            // A SMART status alone is useful but does not imply any of the
            // device-health counters in the detailed section are available.
            Divider().padding(.vertical, 1)
            detailRow("SMART status", status)
        }
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

private struct NetworkRatePoint: Identifiable {
    let timestamp: Date
    let received: Double?
    let sent: Double?
    var id: Date { timestamp }

    init?(snapshot: MetricSnapshot) {
        let received = snapshot.networkReceivedBytesPerSecond
        let sent = snapshot.networkSentBytesPerSecond
        self.received = received.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.sent = sent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard self.received != nil || self.sent != nil else { return nil }
        timestamp = snapshot.timestamp
    }
}

private struct NetworkConnectivityPoint: Identifiable {
    let timestamp: Date
    let reachable: Bool
    var id: Date { timestamp }
}

/// Compact interface activity and network settings, keeping all values tied to Mac readings.
private struct NetworkDetailView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var localSamples: [NetworkRatePoint] = []
    @State private var connectivitySamples: [NetworkConnectivityPoint] = []

    private let downloadColor = Color(red: 0.04, green: 0.57, blue: 0.99)
    private let uploadColor = Color(red: 0.98, green: 0.31, blue: 0.37)

    private var snapshot: MetricSnapshot? { store.snapshot }
    private var details: NetworkDetails? { snapshot?.networkDetails }
    private var panelColor: Color {
        colorScheme == .dark ? Color(white: 0.25) : Color(uiColor: .secondarySystemGroupedBackground)
    }
    private var displayName: String {
        if let name = details?.displayName, !name.isEmpty { return name }
        if let name = details?.interfaceName, !name.isEmpty { return name }
        return "Network interface"
    }
    private var connectionStatus: String {
        if !store.selectedReachable { return "Mac offline" }
        guard let active = details?.isActive else { return "Unavailable" }
        return active ? "UP" : "DOWN"
    }
    private var download: Double? { snapshot?.networkReceivedBytesPerSecond }
    private var upload: Double? { snapshot?.networkSentBytesPerSecond }

    private var history: [NetworkRatePoint] {
        // The aggregate RX/TX pair is already part of the compact history protocol.
        // A short local buffer also covers companions that return no history yet.
        let remote = store.history.compactMap(NetworkRatePoint.init(snapshot:))
        var merged: [Date: NetworkRatePoint] = [:]
        for sample in remote { merged[sample.timestamp] = sample }
        for sample in localSamples { merged[sample.timestamp] = sample }
        let ordered = merged.values.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count > 240 else { return ordered }
        let bucketSize = Int(ceil(Double(ordered.count) / 100))
        var result: [NetworkRatePoint] = []
        result.reserveCapacity(404)
        for start in stride(from: 0, to: ordered.count, by: bucketSize) {
            let bucket = ordered[start..<min(ordered.count, start + bucketSize)]
            let candidates: [NetworkRatePoint?] = [
                bucket.first, bucket.last,
                bucket.max { ($0.received ?? 0) < ($1.received ?? 0) },
                bucket.max { ($0.sent ?? 0) < ($1.sent ?? 0) }
            ]
            var seen = Set<Date>()
            result.append(contentsOf: candidates.compactMap { $0 }
                .filter { seen.insert($0.timestamp).inserted }
                .sorted { $0.timestamp < $1.timestamp })
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 13) {
                macHeader
                VStack(alignment: .leading, spacing: 14) {
                    ratesCard
                    trafficCard
                    interfaceCard
                    addressCard
                    processCard
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panelColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { capture(snapshot) }
        .onChange(of: store.snapshot) { _, value in capture(value) }
        .onChange(of: store.selectedName) { _, _ in
            localSamples.removeAll()
            connectivitySamples.removeAll()
        }
    }

    private var macHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(store.selectedDisplayName ?? "Mac")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Circle()
                .fill(store.selectedReachable ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(store.selectedReachable ? "Connected" : "Offline")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var ratesCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let name = details?.interfaceName, !name.isEmpty, name != displayName {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(details?.isActive == true ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                rateGauge("Download", icon: "arrow.down", rate: download, color: downloadColor)
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 1, height: 66)
                    .accessibilityHidden(true)
                rateGauge("Upload", icon: "arrow.up", rate: upload, color: uploadColor)
            }
            .padding(.vertical, 4)

            sectionTitle("Usage history")
            if history.count >= 2 {
                NetworkActivityPlot(samples: history, downloadColor: downloadColor,
                                    uploadColor: uploadColor)
                    .frame(height: 130)
                    .background(downloadColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Network throughput history")
                    .accessibilityValue("\(history.count) measured samples. Blue download below the middle line; red upload above. Latest download \(networkRate(download)), upload \(networkRate(upload)).")
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                    Text(download == nil && upload == nil ?
                         "Network throughput unavailable" : "History appears after two readings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(downloadColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 14) {
                legend("Download", color: downloadColor)
                legend("Upload", color: uploadColor)
                Spacer(minLength: 0)
                Text("Bytes/s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            sectionTitle("Connectivity history")
            if !connectivitySamples.isEmpty {
                NetworkConnectivityPlot(samples: connectivitySamples)
                    .frame(height: 58)
                    .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Connection probe history")
                    .accessibilityValue("\(connectivitySamples.count) actual checks; \(connectivitySamples.filter(\.reachable).count) successful")
            } else {
                Text("Connectivity history unavailable until a check completes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func rateGauge(_ label: String, icon: String, rate: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(color)
            Text(networkRate(rate))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.62)
                .lineLimit(1)
            Capsule()
                .fill(color)
                .frame(width: 35, height: 3)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(networkRate(rate))
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Interface")
            metricRow("Total upload", MetricFormat.bytes(details?.totalSentBytes))
            metricRow("Total download", MetricFormat.bytes(details?.totalReceivedBytes))
            metricRow("Status", connectionStatus)
            metricRow("Connectivity check", connectivityLabel)
            metricRow("Latency", duration(details?.latencyMs))
            metricRow("Jitter", duration(details?.jitterMs))
            Text("Traffic totals are interface counters; connectivity is an ICMP probe")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var connectivityLabel: String {
        if !store.selectedReachable { return "Mac offline" }
        guard let status = details?.connectivityStatus else { return "Unavailable" }
        return status ? "UP" : "DOWN"
    }

    private func duration(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + " ms"
    }

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Interface")
            metricRow("Name", displayName)
            metricRow("Type", available(details?.connectionType))
            metricRow("BSD interface", available(details?.interfaceName))
            metricRow("Status", connectionStatus)
            if let hardwareAddress = details?.hardwareAddress, !hardwareAddress.isEmpty {
                metricRow("Physical address", hardwareAddress)
            }
            if let ssid = details?.ssid, !ssid.isEmpty {
                metricRow("Network", ssid)
            }
            if let speed = details?.linkSpeedMbps, speed.isFinite, speed > 0 {
                metricRow("Link speed", speed.formatted(.number.precision(.fractionLength(0...1))) + " Mbps")
            }
            if let standard = details?.wifiStandard, !standard.isEmpty {
                metricRow("Wi-Fi standard", standard)
            }
            if let channel = details?.wifiChannel, !channel.isEmpty {
                metricRow("Wi-Fi channel", channel)
            }
            if let rssi = details?.wifiRSSI { metricRow("Signal (RSSI)", "\(rssi) dBm") }
            if let noise = details?.wifiNoise { metricRow("Noise", "\(noise) dBm") }
        }
    }

    private var formattedDNS: String {
        guard let servers = details?.dnsServers, !servers.isEmpty else { return "Unavailable" }
        return servers.joined(separator: ", ")
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Address")
            metricRow("Local IPv4", available(details?.localIPv4))
            metricRow("Local IPv6", available(details?.localIPv6))
            metricRow("Gateway", available(details?.gatewayIPv4))
            metricRow("DNS servers", formattedDNS)
        }
    }

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Top processes")
            if dynamicTypeSize.isAccessibilitySize {
                Text("Process · download and upload rates")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Received").frame(width: 75, alignment: .trailing)
                    Text("Sent").frame(width: 75, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            if let processes = details?.topProcesses {
                let ranked = Array(processes.sorted {
                    networkSortableRate($0.receivedBytesPerSecond) + networkSortableRate($0.sentBytesPerSecond) >
                    networkSortableRate($1.receivedBytesPerSecond) + networkSortableRate($1.sentBytesPerSecond)
                }.prefix(8))
                if ranked.isEmpty {
                    Text("No processes reported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ranked, id: \.pid) { process in processRow(process) }
                }
            } else {
                Text("Per-process network readings unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if details?.topProcesses != nil {
                Text("Process rates include traffic across all network interfaces")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func processRow(_ process: NetworkProcess) -> some View {
        let name = process.name.isEmpty ? "PID \(process.pid)" : process.name
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.medium))
                Text("Received \(networkRate(process.receivedBytesPerSecond))")
                    .font(.caption).foregroundStyle(downloadColor)
                Text("Sent \(networkRate(process.sentBytesPerSecond))")
                    .font(.caption).foregroundStyle(uploadColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), process \(process.pid)")
            .accessibilityValue("Received \(networkRate(process.receivedBytesPerSecond)), sent \(networkRate(process.sentBytesPerSecond))")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "app.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 19, height: 19)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(networkRate(process.receivedBytesPerSecond))
                    .foregroundStyle(downloadColor)
                    .frame(width: 75, alignment: .trailing)
                Text(networkRate(process.sentBytesPerSecond))
                    .foregroundStyle(uploadColor)
                    .frame(width: 75, alignment: .trailing)
            }
            .font(.caption)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), process \(process.pid)")
            .accessibilityValue("Received \(networkRate(process.receivedBytesPerSecond)), sent \(networkRate(process.sentBytesPerSecond))")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 9) {
            Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
        }
        .padding(.vertical, 3)
    }

    private func legend(_ name: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func available(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "Unavailable" }
        return text
    }

    private func capture(_ snapshot: MetricSnapshot?) {
        guard let snapshot else { return }
        if let point = NetworkRatePoint(snapshot: snapshot) {
            if localSamples.last?.timestamp == point.timestamp { localSamples[localSamples.count - 1] = point }
            else { localSamples.append(point) }
            if localSamples.count > 180 { localSamples.removeFirst(localSamples.count - 180) }
        }
        if let reachable = snapshot.networkDetails?.connectivityStatus {
            let point = NetworkConnectivityPoint(timestamp: snapshot.timestamp, reachable: reachable)
            if connectivitySamples.last?.timestamp == point.timestamp {
                connectivitySamples[connectivitySamples.count - 1] = point
            } else { connectivitySamples.append(point) }
            if connectivitySamples.count > 64 { connectivitySamples.removeFirst(connectivitySamples.count - 64) }
        }
    }
}

private func networkRate(_ rate: Double?) -> String {
    guard let rate, rate.isFinite, rate >= 0 else { return "—" }
    if rate == 0 { return "0 B/s" }
    return MetricFormat.rate(rate)
}

private func networkSortableRate(_ rate: Double?) -> Double {
    guard let rate, rate.isFinite, rate >= 0 else { return 0 }
    return rate
}

/// Draw two separate colored paths so independent series cannot inherit each other's color.
private struct NetworkActivityPlot: View {
    let samples: [NetworkRatePoint]
    let downloadColor: Color
    let uploadColor: Color

    var body: some View {
        // Each direction has its own visual scale: 9 KB/s downloads must remain
        // visible beside a 5 MB/s upload. Displayed values stay in real B/s.
        let downloadScale = diskChartScale(samples.compactMap(\.received))
        let uploadScale = diskChartScale(samples.compactMap(\.sent))
        Canvas { context, size in
            let baseline = size.height / 2
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: 0, y: baseline))
            zeroLine.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(zeroLine, with: .color(.secondary.opacity(0.30)), lineWidth: 0.8)

            drawSeries(context, size: size, scale: uploadScale, receives: false, color: uploadColor)
            drawSeries(context, size: size, scale: downloadScale, receives: true, color: downloadColor)
        }
        .accessibilityHidden(true)
    }

    private func drawSeries(_ context: GraphicsContext, size: CGSize, scale: Double,
                            receives: Bool, color: Color) {
        guard let firstTime = samples.first?.timestamp.timeIntervalSince1970,
              let lastTime = samples.last?.timestamp.timeIntervalSince1970 else { return }
        let elapsed = max(0.001, lastTime - firstTime)
        let baseline = size.height / 2
        let height = baseline - 7
        var run: [CGPoint] = []

        func paint(_ values: [CGPoint]) {
            guard !values.isEmpty else { return }
            var line = Path()
            line.addLines(values)
            if values.count == 1, let point = values.first {
                line.addLine(to: CGPoint(x: point.x + 0.5, y: point.y))
            }
            var area = line
            if let first = values.first, let last = values.last {
                area.addLine(to: CGPoint(x: last.x, y: baseline))
                area.addLine(to: CGPoint(x: first.x, y: baseline))
                area.closeSubpath()
            }
            context.fill(area, with: .color(color.opacity(receives ? 0.62 : 0.58)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.7,
                                                                       lineCap: .round, lineJoin: .round))
        }

        for (index, sample) in samples.enumerated() {
            let value = receives ? sample.received : sample.sent
            if let value {
                // Large chronological gaps start a new path, preventing disconnected periods from
                // looking like continuous measured traffic.
                if index > 0, !run.isEmpty {
                    let prior = samples[index - 1].timestamp.timeIntervalSince1970
                    let gap = sample.timestamp.timeIntervalSince1970 - prior
                    let typicalGap = max(2, elapsed / Double(max(1, samples.count - 1)))
                    if gap > typicalGap * 4 { paint(run); run.removeAll() }
                }
                let x = size.width * (sample.timestamp.timeIntervalSince1970 - firstTime) / elapsed
                let magnitude = height * min(1, value / scale)
                let y = baseline + (receives ? magnitude : -magnitude)
                run.append(CGPoint(x: x, y: y))
            } else {
                paint(run)
                run.removeAll()
            }
        }
        paint(run)
    }
}

/// A successful ICMP check is one green bar; a failed check is one red tick.
/// Unknown checks have no bar, and history starts with the first real result.
private struct NetworkConnectivityPlot: View {
    let samples: [NetworkConnectivityPoint]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let count = min(samples.count, 64)
            let shown = Array(samples.suffix(count))
            let spacing = size.width / CGFloat(max(1, count))
            let width = max(1, min(4, spacing - 1.2))
            for (index, sample) in shown.enumerated() {
                let x = CGFloat(index) * spacing + max(0, (spacing - width) / 2)
                let height: CGFloat = sample.reachable ? size.height - 8 : 9
                let bar = CGRect(x: x, y: size.height - height - 4, width: width, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: width / 2),
                             with: .color(sample.reachable ? .green : .red.opacity(0.70)))
            }
        }
        .accessibilityHidden(true)
    }
}
