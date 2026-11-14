import ActivityCore
import SwiftUI

@main
struct StatsApp: App {
    var body: some Scene {
        WindowGroup { PhoneRootView() }
    }
}

private struct PhoneRootView: View {
    @StateObject private var nearby = NearbyMacStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if nearby.selectedName != nil {
                    NearbyMacsView(store: nearby)
                } else {
                    WelcomeFlowView(store: nearby)
                }
            }
            .navigationTitle("Nearby Macs")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(
                get: { nearby.sessionActive },
                set: { if !$0 { nearby.endSession() } }
            )) {
                OverviewView(nearby: nearby)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: nearby.suspendForBackground()
            case .active: nearby.resumeFromBackground()
            default: break
            }
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var nearby: NearbyMacStore
    @State private var showSettings = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(DiskDisplayPreference.selectedDiskKey) private var selectedDiskID = ""
    @AppStorage("Stats.showRemovableDisks") private var showRemovableDisks = false
    @AppStorage(DiskDisplayPreference.showSpeedKey) private var showDiskSpeed = false
    @AppStorage(DiskDisplayPreference.showTextKey) private var showDiskText = false
    @AppStorage(DiskDisplayPreference.speedBaseKey) private var diskSpeedBase = "byte"
    @AppStorage(DiskDisplayPreference.speedUnitKey) private var diskSpeedUnit = "auto"
    @AppStorage(DiskDisplayPreference.textTemplateKey) private var diskTextTemplate = "$capacity.free/$capacity.total"

    private var displayed: MetricSnapshot {
        nearby.snapshot ?? MetricSnapshot(machineName: nearby.selectedDisplayName ?? "Mac")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("System activity")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    NavigationLink {
                        MetricDetailView(kind: .cpu, store: nearby)
                    } label: {
                        MetricCard(title: "CPU", icon: "cpu", tint: .orange,
                                   value: MetricFormat.percent(displayed.cpuFraction),
                                   detail: "Processor load", fraction: displayed.cpuFraction)
                    }
                    NavigationLink {
                        MetricDetailView(kind: .memory, store: nearby)
                    } label: {
                        MetricCard(title: "Memory", icon: "memorychip", tint: .purple,
                                   value: MetricFormat.ramBytes(displayed.memoryUsedBytes),
                                   detail: "of \(MetricFormat.ramBytes(displayed.memoryTotalBytes)) used",
                                   fraction: fraction(displayed.memoryUsedBytes, displayed.memoryTotalBytes))
                    }
                }
                .buttonStyle(.plain)

                VStack(spacing: 12) {
                    NavigationLink {
                        MetricDetailView(kind: .storage, store: nearby)
                    } label: {
                        StorageCard(snapshot: displayed, volume: selectedDisk,
                                    showSpeed: showDiskSpeed, speedBase: diskSpeedBase,
                                    speedUnit: diskSpeedUnit, showText: showDiskText,
                                    textTemplate: diskTextTemplate)
                    }
                    NavigationLink {
                        MetricDetailView(kind: .network, store: nearby)
                    } label: {
                        NetworkCard(snapshot: displayed)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Dashboard settings")
            }
        }
        .sheet(isPresented: $showSettings) { DashboardSettingsView(nearby: nearby) }
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private var selectedDisk: DiskVolume? {
        DiskDisplayPreference.selectedVolume(in: displayed, id: selectedDiskID,
                                             showRemovable: showRemovableDisks)
    }

    private func fraction(_ used: UInt64?, _ total: UInt64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

private struct DashboardSettingsView: View {
    @ObservedObject var nearby: NearbyMacStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StatsHapticPreference.enabledKey) private var hapticsEnabled = true
    @AppStorage(DiskDisplayPreference.showSpeedKey) private var showDiskSpeed = false
    @AppStorage(DiskDisplayPreference.showTextKey) private var showDiskText = false
    @State private var showAbout = false

    var body: some View {
        NavigationStack {
            Form {
                Section("System activity") {
                    HapticToggle(title: "Disk read and write speeds", isOn: $showDiskSpeed)
                    HapticToggle(title: "Disk text", isOn: $showDiskText)
                }
                Section("Interaction") {
                    HapticToggle(title: "Haptics", isOn: $hapticsEnabled, controlsHaptics: true)
                }
                Section {
                    Button("About This Mac") { showAbout = true }
                }
                Section {
                    NavigationLink {
                        PairedMacsSettingsView(store: nearby)
                    } label: {
                        LabeledContent("Paired Macs", value: "\(nearby.pairedNames.count)")
                    }
                }
                Section {
                    StatsSettingsFooter()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAbout) { AboutThisMacView(store: nearby) }
        }
    }
}

private struct StatsSettingsFooter: View {
    private let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Stats"
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

    var body: some View {
        VStack(spacing: 0) {
            Image("StatsSettingsIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .accessibilityHidden(true)

            Text(name)
                .font(.headline)
                .padding(.top, 14)
            Text("Version \(version) (\(build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("© 2026 Ishtiaq Ul Haq Syed\nAll rights reserved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, 28)
    }
}

private struct AboutThisMacView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    MacWindowLight(enabled: true)
                        .frame(width: 23, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close About This Mac")
                MacWindowLight(enabled: false)
                    .frame(width: 23, height: 30)
                    .accessibilityHidden(true)
                MacWindowLight(enabled: false)
                    .frame(width: 23, height: 30)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 0) {
                    if let info = store.aboutInfo {
                        deviceImage(for: info)
                            .frame(width: 190, height: 190)

                        Text(info.modelName)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 258, height: 30)
                            .padding(.top, 7)

                        if let chip = info.chip {
                            Text(chip.replacingOccurrences(of: "Apple ", with: ""))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(height: 18)
                        }

                        VStack(spacing: 4) {
                            aboutRow("Chip", info.chip)
                            aboutRow("Memory", info.memory)
                            aboutRow("Startup disk", info.startupDisk)
                            aboutRow("Serial number", info.serialNumber)
                            aboutRow("macOS", info.macOS)
                        }
                        .padding(.top, 16)

                        Text("™ and © 1983-2026 Apple Inc.\nAll Rights Reserved.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.46))
                            .multilineTextAlignment(.center)
                            .padding(.top, 32)
                    } else if let error = store.aboutError {
                        VStack(spacing: 16) {
                            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                                .font(.system(size: 36, weight: .light))
                            Text(error)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.center)
                            Button("Try Again") { store.loadAbout(force: true) }
                        }
                        .foregroundStyle(.secondary)
                        .padding(.top, 130)
                    } else {
                        Image(systemName: "desktopcomputer")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(44)
                            .frame(width: 190, height: 190)
                        Text("Mac")
                            .font(.system(size: 23, weight: .semibold))
                            .frame(height: 30)
                            .padding(.top, 7)
                        Text("—")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 18)
                        VStack(spacing: 4) {
                            aboutRow("Chip", nil)
                            aboutRow("Memory", nil)
                            aboutRow("Startup disk", nil)
                            aboutRow("Serial number", nil)
                            aboutRow("macOS", nil)
                        }
                        .padding(.top, 16)
                        .accessibilityLabel("Retrieving Mac details")
                    }
                }
                .frame(maxWidth: 280)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .presentationBackground(Color(uiColor: .systemBackground))
        .presentationDetents([.height(500), .large])
        .presentationDragIndicator(.hidden)
        .task { store.loadAbout() }
    }

    @ViewBuilder
    private func deviceImage(for info: MacAboutInfo) -> some View {
        if let data = info.imagePNG, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "desktopcomputer")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(white: 0.54))
                .padding(32)
        }
    }

    private func aboutRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.primary)
            Text(value ?? "—")
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.primary.opacity(0.70))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 14))
        .frame(width: 264, height: 20)
    }
}

private struct MacWindowLight: View {
    let enabled: Bool

    var body: some View {
        Image(enabled ? "MacWindowClose" : "MacWindowDisabled")
            .resizable()
            .interpolation(.high)
            .frame(width: 14, height: 14)
    }
}

struct PairingView: View {
    @ObservedObject var store: NearbyMacStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StatsHapticPreference.enabledKey) private var hapticsEnabled = true
    @AppStorage(PhoneNamePreference.key) private var phoneName = PhoneNamePreference.deviceName
    @State private var manualPasscode = ""
    @State private var pairingError: String?
    @State private var isPairing = false
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var showManualAddress = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DisclosureGroup("Connect using IP address", isExpanded: $showManualAddress) {
                        TextField("Mac IP address", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $manualPort)
                            .keyboardType(.numberPad)
                        SecureField("Five-digit passcode", text: $manualPasscode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        LabeledContent("Name shown on Mac") {
                            TextField("Choose a name", text: $phoneName)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        }
                        Button {
                            isPairing = true
                            store.pairManualWithPasscode(host: manualHost, portString: manualPort,
                                                         code: manualPasscode, phoneName: phoneName) { result in
                                isPairing = false
                                switch result {
                                case .success: dismiss()
                                case .failure(let error): pairingError = error.localizedDescription
                                }
                            }
                        } label: {
                            if isPairing {
                                ProgressView("Pairing…")
                            } else {
                                Text("Pair with address")
                            }
                        }
                        .disabled(isPairing || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || UInt16(manualPort) == nil || manualPasscode.count != 5
                                  || phoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || phoneName.count > 60)
                    }
                } header: { Text("Manual address") }
                footer: { Text("If your Mac isn't discovered, enter the local address and port shown in Stats Companion.") }

                Section("Preferences") {
                    HapticToggle(title: "Haptics", isOn: $hapticsEnabled, controlsHaptics: true)
                }

                Section {
                    NavigationLink {
                        PairedMacsSettingsView(store: store)
                    } label: {
                        LabeledContent("Paired Macs", value: "\(store.pairedNames.count)")
                    }
                }

                Section {
                    StatsSettingsFooter()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Mac connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Pairing failed", isPresented: Binding(
                get: { pairingError != nil },
                set: { if !$0 { pairingError = nil } }
            )) {
                Button("OK") { pairingError = nil }
            } message: { Text(pairingError ?? "") }
        }
    }
}

private struct PairedMacsSettingsView: View {
    @ObservedObject var store: NearbyMacStore
    @State private var macToRevoke: NearbyMacStore.PairedMac?
    @State private var revokeFailed = false

    var body: some View {
        Form {
            if store.pairedMacs.isEmpty {
                ContentUnavailableView("No Paired Macs", systemImage: "macbook.and.iphone",
                                       description: Text("Pair with a nearby Mac or use its IP address to add one."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(store.pairedMacs) { mac in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mac.name).font(.headline)
                                if mac.name != mac.id {
                                    Text(mac.id).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Text(mac.isReachable ? "Reachable" : mac.isNearby ? "Nearby" : "Not nearby")
                                    .font(.subheadline)
                                    .foregroundStyle(mac.isReachable ? .green : .secondary)
                            }
                            Spacer(minLength: 0)
                            if mac.isCurrent {
                                Text("Current")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if store.revokingName == mac.id {
                            ProgressView("Revoking pairing…")
                                .font(.subheadline)
                        } else {
                            Button("Revoke Pairing", role: .destructive) { macToRevoke = mac }
                                .font(.subheadline)
                                .disabled(!store.canRevoke(mac))
                        }
                        if !mac.isNearby && !mac.isReachable {
                            Text("Connect to this Mac to revoke its pairing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Paired Macs")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Revoke pairing?", isPresented: Binding(
            get: { macToRevoke != nil },
            set: { if !$0 { macToRevoke = nil } }
        ), titleVisibility: .visible) {
            if let macToRevoke {
                Button("Revoke \(macToRevoke.name)", role: .destructive) {
                    store.revokePairing(for: macToRevoke.id) { succeeded in
                        revokeFailed = !succeeded
                    }
                    self.macToRevoke = nil
                }
            }
            Button("Cancel", role: .cancel) { macToRevoke = nil }
        } message: {
            Text("This removes the pairing from both the Mac and this iPhone. You will need a new passcode to connect again.")
        }
        .alert("Couldn’t revoke pairing", isPresented: $revokeFailed) {
            Button("OK") { revokeFailed = false }
        } message: {
            Text("The Mac did not confirm the request. Check that Stats Companion is running and try again.")
        }
    }
}

private struct MetricCard: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let detail: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if let fraction {
                GeometryReader { proxy in
                    Capsule().fill(tint.opacity(0.13))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint)
                                .frame(width: proxy.size.width * min(1, max(0, fraction)))
                        }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
        .statsCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show \(title.lowercased()) details")
    }
}

private struct StorageCard: View {
    let snapshot: MetricSnapshot
    let volume: DiskVolume?
    let showSpeed: Bool
    let speedBase: String
    let speedUnit: String
    let showText: Bool
    let textTemplate: String

    private var free: UInt64? { volume?.freeBytes ?? snapshot.diskFreeBytes }
    private var total: UInt64? { volume?.totalBytes ?? snapshot.diskTotalBytes }
    private var usedFraction: Double? {
        guard let free, let total, total > 0 else { return nil }
        return min(1, max(0, 1 - Double(free) / Double(total)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage").font(.subheadline.weight(.semibold))
                    Text(volume?.name ?? "Startup disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MetricFormat.bytes(free))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("free of \(MetricFormat.bytes(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let usedFraction {
                GeometryReader { proxy in
                    Capsule().fill(Color.blue.opacity(0.13))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.blue)
                                .frame(width: proxy.size.width * usedFraction)
                        }
                }
                .frame(height: 5)
                .accessibilityLabel("\(MetricFormat.percent(usedFraction)) used")
            }

            if showSpeed {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        speedLabel("Read", symbol: "arrow.down", value: volume?.readBytesPerSecond)
                        speedLabel("Write", symbol: "arrow.up", value: volume?.writeBytesPerSecond)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        speedLabel("Read", symbol: "arrow.down", value: volume?.readBytesPerSecond)
                        speedLabel("Write", symbol: "arrow.up", value: volume?.writeBytesPerSecond)
                    }
                }
            }

            if showText {
                Divider()
                Label(DiskDisplayPreference.text(textTemplate, volume: volume), systemImage: "textformat")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show storage details")
    }

    private func speedLabel(_ title: String, symbol: String, value: Double?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(title == "Read" ? .blue : .red)
            Text(title).foregroundStyle(.secondary)
            Text(DiskDisplayPreference.rate(value, base: speedBase, unit: speedUnit))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct NetworkCard: View {
    let snapshot: MetricSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text("Network")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "network")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(width: 34, height: 34)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 16) {
                rate("Download", icon: "arrow.down", value: snapshot.networkReceivedBytesPerSecond)
                Divider()
                rate("Upload", icon: "arrow.up", value: snapshot.networkSentBytesPerSecond)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show network details")
    }

    private func rate(_ name: String, icon: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(name, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(MetricFormat.rate(value))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func statsCardBackground() -> some View {
        self
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
