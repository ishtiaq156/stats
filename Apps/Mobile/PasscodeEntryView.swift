import CoreHaptics
import os
import SwiftUI
import UIKit

enum StatsHapticPreference {
    static let enabledKey = "StatsForIOS.hapticsEnabled"
}

@MainActor
private final class PasscodeFeedback: ObservableObject {
    private static let logger = Logger(subsystem: "com.ishtiaqsyed.StatsForIOS", category: "PasscodeHaptics")
    private let fallbackDigit = UIImpactFeedbackGenerator(style: .rigid)
    private let fallbackDelete = UISelectionFeedbackGenerator()
    private let result = UINotificationFeedbackGenerator()
    private var engine: CHHapticEngine?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            Self.logger.warning("Core Haptics is unavailable on this device")
            return
        }
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = true
        } catch {
            Self.logger.error("Could not create haptic engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepare() {
        do {
            try engine?.start()
        } catch {
            Self.logger.error("Could not start haptic engine: \(error.localizedDescription, privacy: .public)")
        }
        fallbackDigit.prepare()
        fallbackDelete.prepare()
        result.prepare()
    }

    func keyPressed(isDelete: Bool) {
        if !playTap(intensity: isDelete ? 0.5 : 0.85) {
            if isDelete {
                fallbackDelete.selectionChanged()
            } else {
                fallbackDigit.impactOccurred()
            }
        }
        fallbackDigit.prepare()
        fallbackDelete.prepare()
    }

    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        result.notificationOccurred(type)
        result.prepare()
    }

    private func playTap(intensity: Float) -> Bool {
        guard let engine else { return false }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient,
                                      parameters: [
                                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                                      ], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.start()
            try engine.makePlayer(with: pattern).start(atTime: 0)
            return true
        } catch {
            Self.logger.error("Could not play keypad haptic: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

enum PhoneNamePreference {
    static let key = "StatsForIOS.pairingPhoneName"

    @MainActor
    static var deviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : String(name.prefix(60))
    }
}

struct PasscodeEntryView: View {
    let device: NearbyMacStore.Device
    @ObservedObject var store: NearbyMacStore
    let onPaired: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(StatsHapticPreference.enabledKey) private var hapticsEnabled = true
    @AppStorage(PhoneNamePreference.key) private var phoneName = PhoneNamePreference.deviceName
    @State private var code = ""
    @State private var isPairing = false
    @State private var shakePhase: CGFloat = 0
    @State private var showingFailure = false
    @State private var editingPhoneName = false
    @State private var proposedPhoneName = ""
    @StateObject private var feedback = PasscodeFeedback()

    private let rows = [["1", "2", "3"], ["4", "5", "6"],
                        ["7", "8", "9"], ["", "0", ""]]

    var body: some View {
        GeometryReader { geometry in
            let keySize = min(104, max(64, min((geometry.size.width - 92) / 3.3,
                                               (geometry.size.height - 320) / 4.5)))
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Spacer()
                        Button {
                            proposedPhoneName = phoneName
                            editingPhoneName = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit phone name shown on Mac, currently \(phoneName)")
                        .disabled(isPairing)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .medium))
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Close passcode entry")
                        .disabled(isPairing)
                    }

                    Spacer(minLength: 28)

                    VStack(spacing: 0) {
                        Text("Enter Mac Passcode")
                            .font(.system(size: 31, weight: .semibold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)

                        Text("5-digit code from Stats Companion")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 9)

                        HStack(spacing: 4) {
                            Text("Pairing as")
                            Text(phoneName).fontWeight(.semibold).lineLimit(1)
                        }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 8)

                        HStack(spacing: 25) {
                            ForEach(0..<5) { index in
                                Circle()
                                    .fill(index < code.count ? Color.white : Color.clear)
                                    .frame(width: 13, height: 13)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                            }
                        }
                        .modifier(PasscodeShake(phase: shakePhase))
                        .padding(.top, 28)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(code.count) of 5 digits entered")

                        ZStack {
                            if isPairing {
                                ProgressView()
                                    .tint(.white)
                                    .accessibilityLabel("Pairing with \(store.displayName(for: device))")
                            }
                        }
                        .font(.footnote)
                        .frame(height: 48)
                        .padding(.top, 8)
                    }

                    Spacer(minLength: 30)

                    keypad(size: keySize)

                    Spacer(minLength: 28)

                    HStack {
                        Button("Paste code") { pasteCode() }
                            .disabled(isPairing || showingFailure)
                        Spacer()
                        Button("Delete") { deleteDigit() }
                            .disabled(isPairing || showingFailure || code.isEmpty)
                            .opacity(code.isEmpty ? 0 : 1)
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                }
                .padding(.horizontal, 26)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background {
            ZStack {
                Color(red: 0.09, green: 0.075, blue: 0.095)
                Circle()
                    .fill(Color(red: 0.55, green: 0.23, blue: 0.13).opacity(0.55))
                    .frame(width: 430, height: 430)
                    .blur(radius: 120)
                    .offset(x: -160, y: -100)
                Circle()
                    .fill(Color(red: 0.22, green: 0.36, blue: 0.46).opacity(0.48))
                    .frame(width: 370, height: 370)
                    .blur(radius: 115)
                    .offset(x: 190, y: 80)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(isPairing)
        .onAppear { if hapticsEnabled { feedback.prepare() } }
        .alert("Name shown on Mac", isPresented: $editingPhoneName) {
            TextField("Phone name", text: $proposedPhoneName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = proposedPhoneName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 60 { phoneName = trimmed }
            }
            .disabled(proposedPhoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || proposedPhoneName.trimmingCharacters(in: .whitespacesAndNewlines).count > 60)
        } message: {
            Text("This name appears on your Mac after pairing.")
        }
    }

    private func keypad(size: CGFloat) -> some View {
        VStack(spacing: 14) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 18) {
                    ForEach(rows[row], id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: size, height: size)
                        } else {
                            Button { enterDigit(key) } label: {
                                VStack(spacing: 0) {
                                    Text(key)
                                        .font(.system(size: 38, weight: .light, design: .rounded))
                                    Text(keyLetters(for: key))
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(2)
                                        .frame(height: 13)
                                }
                            }
                            .buttonStyle(PasscodeKeyStyle(size: size))
                            .accessibilityLabel(key)
                            .disabled(isPairing || showingFailure)
                        }
                    }
                }
            }
        }
    }

    private func enterDigit(_ digit: String) {
        guard !isPairing, !showingFailure, code.count < 5 else { return }
        if hapticsEnabled { feedback.keyPressed(isDelete: false) }
        code += digit
        if code.count == 5 { pair() }
    }

    private func deleteDigit() {
        guard !isPairing, !showingFailure, !code.isEmpty else { return }
        if hapticsEnabled { feedback.keyPressed(isDelete: true) }
        code.removeLast()
    }

    private func pasteCode() {
        guard !isPairing, !showingFailure,
              let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              pasted.utf8.count == 5,
              pasted.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            if hapticsEnabled { feedback.notify(.warning) }
            UIAccessibility.post(notification: .announcement,
                                 argument: "Copy a five-digit code from Stats Companion.")
            return
        }
        if hapticsEnabled { feedback.keyPressed(isDelete: false) }
        code = pasted
        pair()
    }

    private func pair() {
        let name = phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            proposedPhoneName = phoneName
            editingPhoneName = true
            return
        }
        isPairing = true
        store.pairWithPasscode(device, code: code, phoneName: name) { result in
            isPairing = false
            switch result {
            case .success:
                if hapticsEnabled { feedback.notify(.success) }
                dismiss()
                onPaired()
            case .failure(let error):
                if hapticsEnabled { feedback.notify(.error) }
                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
                showingFailure = true
                withAnimation(.linear(duration: 0.42)) { shakePhase += 4 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(430))
                    code = ""
                    showingFailure = false
                }
            }
        }
    }

    private func keyLetters(for key: String) -> String {
        switch key {
        case "2": "ABC"
        case "3": "DEF"
        case "4": "GHI"
        case "5": "JKL"
        case "6": "MNO"
        case "7": "PQRS"
        case "8": "TUV"
        case "9": "WXYZ"
        default: " "
        }
    }
}

private struct PasscodeKeyStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background {
                if #available(iOS 26, *) {
                    Color.clear
                        .glassEffect(.regular, in: .circle)
                        .overlay(Circle().fill(.white.opacity(configuration.isPressed ? 0.22 : 0.05)))
                } else {
                    Circle()
                        .fill(.white.opacity(configuration.isPressed ? 0.27 : 0.11))
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .overlay(Circle().strokeBorder(.white.opacity(configuration.isPressed ? 0.5 : 0.25)))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct PasscodeShake: GeometryEffect {
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(phase * .pi * 2) * 10, y: 0))
    }
}
