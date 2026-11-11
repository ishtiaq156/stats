import SwiftUI

private enum PairingAppearance {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.06)
    static let card = Color.white.opacity(0.12)
    static let blue = Color(red: 0.02, green: 0.58, blue: 1)
    static let green = Color(red: 0.15, green: 0.82, blue: 0.35)
    static let downloadURL = URL(string: "https://github.com/ishtiaq156/stats")!
}

struct NearbyMacsView: View {
    @ObservedObject var store: NearbyMacStore
    @State private var showConnections = false
    @State private var pairingDevice: NearbyMacStore.Device?

    private var availableDevices: [NearbyMacStore.Device] {
        store.devices
    }

    private var offlineName: String? {
        guard let name = store.selectedName, !store.selectedReachable,
              !store.devices.contains(where: { $0.name == name }) else { return nil }
        return store.selectedDisplayName ?? name
    }

    private var hasAvailableMac: Bool {
        !availableDevices.isEmpty || (store.selectedName != nil && store.selectedReachable)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button { showConnections = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(PairingAppearance.card, in: Circle())
                    }
                    .accessibilityLabel("Mac connection settings")
                }
                .padding(.bottom, 48)

                Text("Nearby Macs")
                    .font(.system(size: 39, weight: .bold))
                    .tracking(-1.2)
                    .accessibilityAddTraits(.isHeader)
                Text("Connect to a Mac on your local network")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 9)
                    .padding(.bottom, 25)

                if let offlineName {
                    ScrollView {
                        VStack(spacing: 32) {
                            if !availableDevices.isEmpty {
                                VStack(spacing: 12) {
                                    ForEach(availableDevices) { device in
                                        macRow(name: store.displayName(for: device), available: true,
                                               pairAgain: device.name == store.selectedName && !store.selectedReachable) {
                                            choose(device)
                                        }
                                    }
                                }
                            }
                            OfflineSearchView()
                                .frame(maxWidth: .infinity)
                            offlineSection(name: offlineName)
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(availableDevices) { device in
                                macRow(name: store.displayName(for: device), available: true,
                                       pairAgain: device.name == store.selectedName && !store.selectedReachable) {
                                    choose(device)
                                }
                            }
                            if let name = store.selectedName, store.selectedReachable,
                               !availableDevices.contains(where: { $0.name == name }) {
                                macRow(name: store.selectedDisplayName ?? name, available: true) {
                                    store.connectToSelectedMac()
                                }
                            }
                            if !hasAvailableMac {
                                ContentUnavailableView("Searching for Macs", systemImage: "network",
                                                       description: Text("Keep Stats Companion open on your Mac."))
                                    .frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                if hasAvailableMac, offlineName == nil {
                    VStack(spacing: 10) {
                        Image(systemName: store.selectedReachable ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(store.selectedReachable ? PairingAppearance.green : PairingAppearance.blue)
                        Text(store.selectedReachable ? "Your Mac is reachable" :
                             availableDevices.count == 1 ? "Mac is available to pair" :
                             "\(availableDevices.count) Macs are available to pair")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, max(22, geometry.size.height * 0.08))
                }

                ShareLink(item: PairingAppearance.downloadURL) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 29))
                            .foregroundStyle(.white.opacity(0.8))
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Add another Mac")
                                .font(.headline)
                            Text("Share the Stats Companion download link with another Mac")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PairingAppearance.card, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share Stats Companion download link to add another Mac")
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PairingAppearance.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .sheet(isPresented: $showConnections) { PairingView(store: store) }
        .sheet(item: $pairingDevice) { device in
            PasscodeEntryView(device: device, store: store, onPaired: {})
        }
    }

    private func choose(_ device: NearbyMacStore.Device) {
        if device.name == store.selectedName {
            if store.selectedReachable { store.connectToSelectedMac() }
            else { pairingDevice = device }
            return
        }
        if store.select(device) { return }
        pairingDevice = device
    }

    private func macRow(name: String, available: Bool, pairAgain: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack(alignment: .topLeading) {
                    Image(systemName: "macmini")
                        .font(.title2)
                        .frame(width: 42, height: 42)
                    if available {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 8, height: 8)
                            .offset(x: -2, y: -1)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline).lineLimit(2)
                    if pairAgain {
                        Text("Pair again")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if available {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 72)
            .background(PairingAppearance.card, in: RoundedRectangle(cornerRadius: 22))
            .foregroundStyle(.white.opacity(available ? 1 : 0.3))
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private func offlineSection(name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Offline")
                .font(.system(size: 38, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("This Mac isn't available right now")
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.52))
                .padding(.bottom, 16)
            macRow(name: name, available: false) {}
        }
    }
}

private struct OfflineSearchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(PairingAppearance.blue.opacity(pulse ? 0.07 : 0.2), lineWidth: 2)
                .frame(width: 188, height: 188)
                .scaleEffect(pulse ? 1.06 : 0.9)
            Circle()
                .stroke(PairingAppearance.blue.opacity(pulse ? 0.25 : 0.12), lineWidth: 2)
                .frame(width: 132, height: 132)
                .scaleEffect(pulse ? 0.92 : 1.08)
            Image(systemName: "wifi")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(PairingAppearance.blue)
                .frame(width: 90, height: 90)
                .background(PairingAppearance.blue.opacity(0.18), in: Circle())
        }
        .frame(width: 206, height: 206)
        .accessibilityLabel("Searching for your Mac")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct SetupSuccessView: View {
    let onFinished: () -> Void
    @State private var ringProgress: CGFloat = 0
    @State private var showCheck = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(PairingAppearance.green.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(PairingAppearance.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if showCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: 49, weight: .medium))
                        .foregroundStyle(PairingAppearance.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 104, height: 104)
            .shadow(color: PairingAppearance.green.opacity(showCheck ? 0.35 : 0), radius: 35)
            .padding(.bottom, 13)

            Text("You’re all set")
                .font(.system(size: 38, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("Stats is ready to discover and connect to Macs on your network")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task {
            if reduceMotion {
                ringProgress = 1
                showCheck = true
                try? await Task.sleep(for: .seconds(0.7))
            } else {
                withAnimation(.easeInOut(duration: 0.9)) { ringProgress = 1 }
                try? await Task.sleep(for: .seconds(0.95))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { showCheck = true }
                try? await Task.sleep(for: .seconds(1.2))
            }
            if !Task.isCancelled { onFinished() }
        }
    }
}

struct PairingTipView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            macMenuExample
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, 24)
            Spacer(minLength: 0)
            Text("How to pair devices")
                .font(.system(size: 26, weight: .bold))
                .padding(.bottom, 9)
            Text("On your Mac, open Stats Companion from the menu bar and copy its five-digit passcode. Then select your Mac here and enter the code.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            Button("Done") { dismiss() }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(PairingAppearance.blue, in: Capsule())
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
        .foregroundStyle(.white)
        .presentationDetents([.height(440)])
        .presentationDragIndicator(.visible)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.1))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.25)) { copied = true }
                try? await Task.sleep(for: .seconds(1.2))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.25)) { copied = false }
            }
        }
    }

    private var macMenuExample: some View {
        VStack(spacing: 12) {
            HStack(spacing: 13) {
                Image("StatsBrandMark")
                    .resizable()
                    .frame(width: 23, height: 23)
                Image(systemName: "cpu")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .foregroundStyle(.white.opacity(0.75))
            .font(.caption)

            VStack(alignment: .leading, spacing: 12) {
                Text("Stats Companion")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Passcode")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                HStack {
                    Text("12345")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.headline)
                        .foregroundStyle(copied ? PairingAppearance.green : .white)
                        .frame(width: 40, height: 40)
                        .background(copied ? PairingAppearance.green.opacity(0.16) : .white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Copy passcode")
                }
                Divider().overlay(.white.opacity(0.15))
                Label("Discoverable on network", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(PairingAppearance.green)
            }
            .padding(17)
            .frame(maxWidth: 285)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example Mac menu with a five-digit passcode and copy button")
    }
}
