import ActivityCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var nearby: NearbyMacStore
    @State private var showSettings = false
    @State private var showAbout = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DiskDisplayPreference.selectedDiskKey) private var selectedDiskID = ""
    @AppStorage("Stats.showRemovableDisks") private var showRemovableDisks = false

    private var selectedDisk: DiskVolume? {
        nearby.snapshot.flatMap {
            DiskDisplayPreference.selectedVolume(in: $0, id: selectedDiskID, showRemovable: showRemovableDisks)
        }
    }

    var body: some View {
        let snapshot = nearby.snapshot
        let storage = DashboardStorage(snapshot: snapshot, volume: selectedDisk)
        let pressure = DashboardMemoryPressure(rawValue: snapshot?.ramDetails?.pressureLevel?.lowercased() ?? "")
        let history = recentSamples(endingAt: snapshot?.timestamp)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DashboardMacCard(
                    name: nearby.selectedDisplayName ?? snapshot?.machineName ?? "Mac",
                    about: nearby.aboutInfo,
                    timestamp: snapshot?.timestamp,
                    connected: nearby.selectedReachable,
                    lowStorage: storage.isLow,
                    memoryPressure: pressure,
                    isRefreshing: nearby.isRefreshingDashboard,
                    openAbout: { showAbout = true },
                    refresh: nearby.refreshDashboard
                )

                activityHeading(showsTrendWindow: history.count > 1)
                    .padding(.top, 8)

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    metricLink(.cpu) {
                        DashboardTrendCard(
                            kind: .cpu, value: MetricFormat.percent(snapshot?.cpuFraction), subtitle: "Processor load",
                            samples: history, fraction: \.cpuFraction, footer: cpuFooter(snapshot?.cpuDetails)
                        )
                    }

                    metricLink(.memory) {
                        DashboardTrendCard(
                            kind: .memory, value: MetricFormat.ramBytes(snapshot?.memoryUsedBytes),
                            subtitle: snapshot?.memoryTotalBytes.map { "of \(MetricFormat.ramBytes($0)) used" } ?? "Memory used",
                            samples: history, fraction: Self.memoryFraction,
                            footer: pressure?.label ?? "Pressure unavailable", footerTint: pressure?.tint
                        )
                    }
                }

                metricLink(.storage) { DashboardStorageCard(storage: storage) }
                metricLink(.network) { DashboardNetworkCard(snapshot: snapshot) }
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background {
            Color(uiColor: .systemGroupedBackground)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.indigo.opacity(colorScheme == .dark ? 0.18 : 0.09), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 480)
                }
                .ignoresSafeArea()
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Dashboard settings")
            }
        }
        .sheet(isPresented: $showSettings) { DashboardSettingsView(nearby: nearby) }
        .sheet(isPresented: $showAbout) { AboutThisMacView(store: nearby) }
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private func activityHeading(showsTrendWindow: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text("System activity")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if showsTrendWindow {
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text("1-minute trends")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricLink<Content: View>(_ kind: MetricKind, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink {
            MetricDetailView(kind: kind, store: nearby)
        } label: {
            content()
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens \(kind.title) details")
        }
        .buttonStyle(.plain)
    }

    private func recentSamples(endingAt end: Date?) -> [MetricSnapshot] {
        guard let end else { return [] }
        let start = end.addingTimeInterval(-DashboardSparkline.duration)
        return nearby.history.filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func memoryFraction(_ snapshot: MetricSnapshot) -> Double? {
        guard let used = snapshot.memoryUsedBytes, let total = snapshot.memoryTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    private func cpuFooter(_ details: CPUDetails?) -> String? {
        if let temperature = details?.temperatureCelsius {
            return "\(temperature.formatted(.number.precision(.fractionLength(0)))) °C"
        }
        if let frequency = details?.frequencyMHz {
            return "\((frequency / 1000).formatted(.number.precision(.fractionLength(2)))) GHz avg"
        }
        return details?.logicalCores.map { "\($0) logical cores" }
    }
}

private enum DashboardMemoryPressure: String {
    case normal, warning, critical

    var label: String {
        switch self {
        case .normal: "Normal pressure"
        case .warning: "Elevated pressure"
        case .critical: "Critical pressure"
        }
    }

    var tint: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct DashboardMacCard: View {
    let name: String
    let about: MacAboutInfo?
    let timestamp: Date?
    let connected: Bool
    let lowStorage: Bool
    let memoryPressure: DashboardMemoryPressure?
    let isRefreshing: Bool
    let openAbout: () -> Void
    let refresh: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deviceImage: UIImage?

    private let warningTint = Color(red: 1, green: 0.79, blue: 0.43)

    private var attention: String? {
        let alerts = [lowStorage ? "Low storage" : nil,
                      memoryPressure == .warning || memoryPressure == .critical ? memoryPressure?.label : nil]
        let message = alerts.compactMap { $0 }.joined(separator: " · ")
        return message.isEmpty ? nil : message
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: openAbout) {
                HStack(spacing: 11) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        device
                        Rectangle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 1, height: 54)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        identity
                        if connected, let attention {
                            Label(attention, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(warningTint)
                        }
                        statusRow
                            .padding(.trailing, 36)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens About This Mac")

            Button(action: refresh) {
                Group {
                    if isRefreshing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Refreshing dashboard" : "Refresh dashboard")
            .padding(.trailing, 3)
            .padding(.bottom, 4)
        }
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [
                    Color(red: 0.10, green: 0.14, blue: 0.26),
                    Color(red: 0.12, green: 0.19, blue: 0.35)
                ], startPoint: .bottomLeading, endPoint: .topTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.16))
                }
        }
        .onChange(of: about?.imagePNG, initial: true) { _, data in
            deviceImage = data.flatMap { UIImage(data: $0) }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.title2.weight(.bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let about {
                let model = [about.modelName == name ? nil : about.modelName, about.chip]
                    .compactMap { $0 }.joined(separator: " · ")
                if !model.isEmpty {
                    Text(model)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
        }
    }

    private var device: some View {
        Group {
            if let deviceImage {
                Image(uiImage: deviceImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
        .frame(width: 60, height: 60)
        .accessibilityHidden(true)
    }

    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                status.fixedSize()
                Spacer(minLength: 0)
                if let timestamp { lastUpdate(timestamp).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 2) {
                status
                if let timestamp { lastUpdate(timestamp) }
            }
        }
    }

    private var status: some View {
        Label(connected ? "Connected" : "Reconnecting",
              systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(connected ? Color(red: 0.46, green: 0.95, blue: 0.77) : warningTint)
    }

    private func lastUpdate(_ timestamp: Date) -> some View {
        Text("Updated \(timestamp.formatted(date: .omitted, time: .shortened))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
            .accessibilityLabel("Last update \(timestamp.formatted(date: .omitted, time: .standard))")
    }
}

private struct DashboardCardHeading: View {
    let kind: MetricKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(kind.tint)
                .frame(minWidth: 30, minHeight: 30)
                .background(kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct DashboardTrendCard: View {
    let kind: MetricKind
    let value: String
    let subtitle: String
    let samples: [MetricSnapshot]
    let fraction: (MetricSnapshot) -> Double?
    let footer: String?
    var footerTint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DashboardCardHeading(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if samples.contains(where: { fraction($0)?.isFinite == true }) {
                DashboardSparkline(samples: samples, fraction: fraction, tint: kind.tint)
                    .frame(height: 36)
                    .accessibilityHidden(true)
            } else {
                Text("Trend unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 36, alignment: .leading)
            }

            if let footer {
                HStack(spacing: 5) {
                    if let footerTint {
                        Circle()
                            .fill(footerTint)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(footer)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard(tint: kind.tint)
    }
}

private struct DashboardSparkline: View {
    static let duration: TimeInterval = 60
    let samples: [MetricSnapshot]
    let fraction: (MetricSnapshot) -> Double?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let baseline = size.height - 2
            var grid = Path()
            for y in [2, size.height / 2, baseline] {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

            guard let end = samples.last?.timestamp else { return }
            var previous: Date?
            var segment: [CGPoint] = []
            func drawSegment() {
                guard let first = segment.first, let last = segment.last else { return }
                if segment.count > 1 {
                    var line = Path()
                    line.move(to: first)
                    line.addLines(segment)
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: baseline))
                    area.addLine(to: CGPoint(x: first.x, y: baseline))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.32), tint.opacity(0.04)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: baseline)))
                    context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if previous == end || segment.count == 1 {
                    let dot = Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4))
                    context.fill(dot, with: .color(tint))
                }
            }
            for sample in samples {
                if let previous, sample.timestamp.timeIntervalSince(previous) > 6 {
                    drawSegment()
                    segment.removeAll(keepingCapacity: true)
                }
                guard let value = fraction(sample), value.isFinite else {
                    drawSegment()
                    segment.removeAll(keepingCapacity: true)
                    previous = nil
                    continue
                }
                let elapsedFraction = 1 + sample.timestamp.timeIntervalSince(end) / Self.duration
                segment.append(CGPoint(x: 2 + elapsedFraction * (size.width - 4),
                                       y: baseline - min(1, max(0, value)) * (baseline - 2)))
                previous = sample.timestamp
            }
            drawSegment()
        }
    }
}

private struct DashboardStorage {
    let snapshot: MetricSnapshot?
    let volume: DiskVolume?

    var free: UInt64? { volume == nil ? snapshot?.diskFreeBytes : volume?.freeBytes }
    var total: UInt64? { volume == nil ? snapshot?.diskTotalBytes : volume?.totalBytes }
    var freeFraction: Double? {
        guard let free, let total, total > 0 else { return nil }
        return min(1, Double(free) / Double(total))
    }
    var isLow: Bool { freeFraction.map { $0 <= 0.10 } ?? false }
}

private struct DashboardStorageCard: View {
    let storage: DashboardStorage
    @AppStorage(DiskDisplayPreference.showSpeedKey) private var showSpeed = false
    @AppStorage(DiskDisplayPreference.showTextKey) private var showText = false
    @AppStorage(DiskDisplayPreference.speedBaseKey) private var speedBase = "byte"
    @AppStorage(DiskDisplayPreference.speedUnitKey) private var speedUnit = "auto"
    @AppStorage(DiskDisplayPreference.textTemplateKey) private var textTemplate = "$capacity.free/$capacity.total"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardCardHeading(kind: .storage)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { freeSpace; diskName }
                VStack(alignment: .leading, spacing: 2) { freeSpace; diskName }
            }

            if let free = storage.freeFraction {
                GeometryReader { proxy in
                    let tint: Color = storage.isLow ? .orange : .blue
                    Capsule()
                        .fill(tint.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(LinearGradient(colors: [tint.opacity(0.58), tint],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * (1 - free))
                        }
                }
                .frame(height: 8)
                .accessibilityHidden(true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        capacity
                        Spacer()
                        capacityStatus(free)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        capacity
                        capacityStatus(free)
                    }
                }
            }

            if showSpeed || showText {
                Divider()
                if showSpeed {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { readSpeed; writeSpeed }
                        VStack(alignment: .leading, spacing: 5) { readSpeed; writeSpeed }
                    }
                }
                if showText {
                    Label(DiskDisplayPreference.text(textTemplate, volume: storage.volume), systemImage: "textformat")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(tint: storage.isLow ? .orange : .blue)
    }

    private var freeSpace: some View {
        Text(storage.free.map { "\(MetricFormat.bytes($0)) free" } ?? "Capacity unavailable")
            .font(.system(.title2, design: .rounded, weight: .semibold))
            .monospacedDigit()
    }

    private var diskName: some View {
        Text(storage.volume?.name ?? "Startup disk")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var capacity: some View {
        Text("\(MetricFormat.bytes(storage.total)) total")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func capacityStatus(_ free: Double) -> some View {
        Label {
            Text(storage.isLow ? "\(MetricFormat.percent(free)) left · Low space" : "\(MetricFormat.percent(free)) free")
        } icon: {
            if storage.isLow { Image(systemName: "exclamationmark.triangle") }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var readSpeed: some View {
        speed("Read", symbol: "arrow.down", value: storage.volume?.readBytesPerSecond)
    }

    private var writeSpeed: some View {
        speed("Write", symbol: "arrow.up", value: storage.volume?.writeBytesPerSecond)
    }

    private func speed(_ title: String, symbol: String, value: Double?) -> some View {
        Label {
            Text("\(title) \(DiskDisplayPreference.rate(value, base: speedBase, unit: speedUnit))")
                .monospacedDigit()
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(title == "Read" ? .blue : .red)
        }
        .font(.caption)
    }
}

private struct DashboardNetworkCard: View {
    let snapshot: MetricSnapshot?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var details: NetworkDetails? { snapshot?.networkDetails }
    private var connectionName: String? {
        details?.ssid ?? details?.displayName ?? details?.connectionType
    }
    private var latency: String {
        details?.latencyMs.map { "\($0.formatted(.number.precision(.fractionLength(0)))) ms" } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardCardHeading(kind: .network)
            if let connectionName {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Text(connectionName).font(.subheadline.weight(.medium))
                    if let address = details?.localIPv4 {
                        Text(address)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 9) { rates }
            } else {
                HStack(alignment: .top, spacing: 8) { rates }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(tint: .green)
    }

    @ViewBuilder
    private var rates: some View {
        reading("Download", symbol: "arrow.down", tint: .blue, value: MetricFormat.rate(snapshot?.networkReceivedBytesPerSecond))
        reading("Upload", symbol: "arrow.up", tint: .purple, value: MetricFormat.rate(snapshot?.networkSentBytesPerSecond))
        reading("Latency", symbol: "timer", tint: .green, value: latency)
    }

    private func reading(_ title: String, symbol: String, tint: Color, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func dashboardCard(tint: Color) -> some View {
        self.background {
            let shape = RoundedRectangle(cornerRadius: 19)
            shape
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    shape.fill(LinearGradient(colors: [tint.opacity(0.09), .clear],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay { shape.strokeBorder(tint.opacity(0.20)) }
        }
    }
}
