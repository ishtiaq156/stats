import CoreBluetooth
import SwiftUI

private enum SetupStyle {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.06)
    static let blue = Color(red: 0.02, green: 0.58, blue: 1)
    static let muted = Color.white.opacity(0.52)
    static let projectURL = URL(string: "https://github.com/ishtiaq156/stats")!
}

private final class BluetoothPermission: NSObject, ObservableObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?

    func request() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}

struct WelcomeFlowView: View {
    @ObservedObject var store: NearbyMacStore
    @AppStorage("StatsForIOS.setupStep") private var step = 0
    @StateObject private var bluetooth = BluetoothPermission()
    @State private var showPairing = false
    @State private var showSuccess = false
    @State private var showPairingTip = false
    @State private var searchFinished = false
    @AppStorage("StatsForIOS.pairingTipSeen") private var pairingTipSeen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            if step >= 5 {
                NearbyMacsView(store: store)
            } else {
                setupPages
            }
            if showSuccess {
                SetupSuccessView {
                    showSuccess = false
                    if !pairingTipSeen { showPairingTip = true }
                }
                .zIndex(1)
            }
        }
        .background(SetupStyle.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            if step >= 4 { store.startDiscovery() }
            if step >= 5 && !pairingTipSeen { showPairingTip = true }
        }
        .task(id: step) {
            guard step == 4 else { return }
            searchFinished = false
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { searchFinished = true }
        }
        .sheet(isPresented: $showPairing) { PairingView(store: store) }
        .sheet(isPresented: $showPairingTip, onDismiss: { pairingTipSeen = true }) {
            PairingTipView()
        }
    }

    private var setupPages: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    Spacer(minLength: 24)
                    illustration
                        .frame(maxWidth: .infinity)
                        .frame(height: max(260, min(geometry.size.height * 0.44, 410)))
                        .accessibilityHidden(true)
                    Spacer(minLength: 24)
                    controls
                }
                .padding(.horizontal, 30)
                .padding(.top, 72)
                .padding(.bottom, 30)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .background(SetupStyle.background.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    @ViewBuilder private var heading: some View {
        switch step {
        case 0:
            Text("Your Mac, at a glance.")
                .font(.system(size: 43, weight: .bold, design: .rounded))
                .tracking(-1.5)
                .fixedSize(horizontal: false, vertical: true)
        case 1:
            setupHeading("Stats Companion for Mac",
                         subtitle: "Download the Mac app to discover and connect to your Mac from iPhone.")
        case 2:
            setupHeading("Bluetooth permission",
                         subtitle: "Allow Bluetooth access for nearby device support. Stats currently connects to your Mac over your local network.")
        case 3:
            setupHeading("Local Network required",
                         subtitle: "Stats uses your local network to discover and connect to your Mac.")
        default:
            setupHeading("Let’s find your Mac",
                         subtitle: "Make sure Stats Companion is installed and running on your Mac.")
        }
    }

    private func setupHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 39, weight: .bold))
                .tracking(-1.2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 21))
                .foregroundStyle(SetupStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var illustration: some View {
        switch step {
        case 0: HeroPhoneIllustration()
        case 1:
            ShareLink(item: SetupStyle.projectURL) {
                MacDownloadIllustration()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share Stats Companion download link")
        case 2:
            PermissionIllustration(symbol: "bluetooth", label: "Bluetooth", tint: .blue)
        case 3:
            PermissionIllustration(symbol: "wifi", label: "Local Network", tint: .cyan)
        default:
            FindingMacIllustration(searching: store.devices.isEmpty)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if step == 1 || step >= 4 {
                Button { openURL(SetupStyle.projectURL) } label: {
                    Label("Download Stats for Mac", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SetupButtonStyle(primary: false))
            }

            Button(action: continueSetup) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(SetupButtonStyle(primary: true))
            .disabled(step >= 4 && store.devices.isEmpty)

            if step >= 4 {
                Button("Connect using IP address") { showPairing = true }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(SetupStyle.muted)
                    .padding(.top, 5)
                Label(store.discoveryError != nil ? "Nearby search unavailable" :
                        store.devices.isEmpty ? (searchFinished ? "No Mac detected on your network" : "Searching for Macs…") :
                        "\(store.devices.count) Mac\(store.devices.count == 1 ? "" : "s") found nearby",
                      systemImage: store.discoveryError != nil ? "wifi.exclamationmark" :
                          store.devices.isEmpty ? "circle.fill" : "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(store.devices.isEmpty ? SetupStyle.muted : Color.green)
                    .padding(.top, 9)
                if store.discoveryError != nil {
                    Text("You can still pair with your Mac using its local IP address and port.")
                        .font(.footnote)
                        .foregroundStyle(SetupStyle.muted)
                        .multilineTextAlignment(.center)
                }
            } else if step == 0 {
                Text("Terms of Use · Privacy Policy")
                    .font(.footnote)
                    .foregroundStyle(SetupStyle.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
            } else {
                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(SetupStyle.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
    }

    private var footerText: String {
        switch step {
        case 1: "Already installed? Tap Continue"
        case 2, 3: "Tap Allow when prompted"
        default: ""
        }
    }

    private func continueSetup() {
        switch step {
        case 0, 1: step += 1
        case 2:
            bluetooth.request()
            step = 3
        case 3:
            store.startDiscovery()
            step = 4
        default:
            if !store.devices.isEmpty {
                showSuccess = true
                step = 5
            }
        }
    }
}

private struct SetupButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(height: 56)
            .background(primary ? SetupStyle.blue : Color.white.opacity(0.14),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.16)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .opacity(isEnabled ? 1 : 0.28)
    }
}

private struct HeroPhoneIllustration: View {
    @State private var glow = false

    var body: some View {
        ZStack {
            Circle()
                .fill(SetupStyle.blue.opacity(glow ? 0.32 : 0.12))
                .blur(radius: 62)
                .frame(width: 270, height: 270)
            RoundedRectangle(cornerRadius: 42)
                .fill(.black)
                .frame(width: 245, height: 350)
                .overlay {
                    RoundedRectangle(cornerRadius: 42)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 3)
                }
                .overlay {
                    VStack(spacing: 12) {
                        Capsule().fill(.white.opacity(0.25)).frame(width: 65, height: 5)
                            .padding(.bottom, 15)
                        widget("CPU", symbol: "cpu", color: .orange, bars: [0.3, 0.6, 0.4, 0.8, 0.5])
                        widget("Memory", symbol: "memorychip", color: .purple, bars: [0.7, 0.5, 0.8, 0.6, 0.9])
                        widget("Network", symbol: "network", color: .cyan, bars: [0.4, 0.8, 0.5, 0.7, 0.6])
                    }
                    .padding(.horizontal, 19)
                }
                .rotationEffect(.degrees(-7))
                .shadow(color: SetupStyle.blue.opacity(0.24), radius: 35, y: 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }

    private func widget(_ title: String, symbol: String, color: Color, bars: [CGFloat]) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 26)
            Text(title).font(.caption.weight(.semibold))
            Spacer(minLength: 2)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { bar in
                    Capsule().fill(color).frame(width: 4, height: 22 * bar.element)
                }
            }.frame(height: 23)
        }
        .padding(11)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct MacDownloadIllustration: View {
    var body: some View {
        ZStack {
            Circle().fill(SetupStyle.blue.opacity(0.27)).blur(radius: 58)
                .frame(width: 250, height: 250)
            RoundedRectangle(cornerRadius: 32)
                .fill(.white.opacity(0.08))
                .frame(width: 260, height: 240)
                .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.14)))
            Image(systemName: "folder.fill")
                .font(.system(size: 112))
                .foregroundStyle(.cyan.gradient)
                .offset(x: 30, y: 25)
            Image("StatsBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 105, height: 105)
                .rotationEffect(.degrees(-12))
                .offset(x: -45, y: -55)
            Text("Applications")
                .font(.headline)
                .offset(y: 100)
        }
    }
}

private struct PermissionIllustration: View {
    let symbol: String
    let label: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.2)).blur(radius: 56)
                .frame(width: 250, height: 250)
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.13, green: 0.14, blue: 0.17))
                .frame(width: 260, height: 255)
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.14)))
                .overlay {
                    VStack(alignment: .leading, spacing: 17) {
                        Image(systemName: symbol)
                            .font(.system(size: 34, weight: .medium))
                            .frame(width: 56, height: 56)
                            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14))
                        Text("Allow Stats to access \(label)?")
                            .font(.headline)
                        Text(label == "Bluetooth"
                             ? "For nearby device support. Current connections use your local network."
                             : "Needed to find and connect to your Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                        HStack {
                            Text("Don’t Allow")
                            Spacer()
                            Text("Allow").foregroundStyle(tint)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 13)
                    }
                    .padding(24)
                }
        }
    }
}

private struct FindingMacIllustration: View {
    let searching: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                Circle()
                    .strokeBorder(SetupStyle.blue.opacity(0.26 - Double(index) * 0.06), lineWidth: 2)
                    .frame(width: CGFloat(170 + index * 68), height: CGFloat(170 + index * 68))
                    .scaleEffect(pulse ? 1.08 : 0.94)
            }
            Image("StatsBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 148, height: 148)
                .scaleEffect(searching && pulse ? 1.06 : 1)
                .shadow(color: SetupStyle.blue.opacity(0.7), radius: 24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
