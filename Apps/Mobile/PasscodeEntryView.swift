import SwiftUI
import UIKit

enum StatsHapticPreference {
    static let enabledKey = "StatsForIOS.hapticsEnabled"
}

struct PasscodeEntryView: View {
    let device: NearbyMacStore.Device
    @ObservedObject var store: NearbyMacStore
    let onPaired: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(StatsHapticPreference.enabledKey) private var hapticsEnabled = true
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    private let rows = [["1", "2", "3"], ["4", "5", "6"],
                        ["7", "8", "9"], ["", "0", "delete"]]

    var body: some View {
        GeometryReader { geometry in
            let keySize = min(88, max(64, min((geometry.size.width - 96) / 3.4,
                                              (geometry.size.height - 350) / 4)))
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .medium))
                                .frame(width: 42, height: 42)
                                .background(.white.opacity(0.13), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                        }
                        .accessibilityLabel("Close passcode entry")
                        .disabled(isPairing)
                    }

                    Spacer(minLength: 24)

                    VStack(spacing: 0) {
                        Text("Passcode")
                            .font(.system(size: 34, weight: .bold))
                            .accessibilityAddTraits(.isHeader)

                        Text("Enter the 5-digit code shown on your Mac\nto link both devices")
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.52))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)

                        HStack(spacing: 28) {
                            ForEach(0..<5) { index in
                                Circle()
                                    .fill(index < code.count ? Color.white : Color.white.opacity(0.28))
                                    .frame(width: 14, height: 14)
                            }
                        }
                        .padding(.top, 32)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(code.count) of 5 digits entered")
                        .accessibilityHint("Long-press to paste a copied passcode")
                        .contextMenu {
                            Button("Paste code", systemImage: "doc.on.clipboard") { pasteCode() }
                        }

                        Group {
                            if isPairing {
                                ProgressView("Pairing with \(store.displayName(for: device))…")
                                    .tint(.white)
                            } else if let errorMessage {
                                Text(errorMessage)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .font(.footnote)
                        .frame(height: 48)
                        .padding(.top, 8)

                        keypad(size: keySize)
                            .padding(.top, 22)
                    }

                    Spacer(minLength: 28)
                }
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(red: 0.065, green: 0.065, blue: 0.07).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(isPairing)
    }

    private func keypad(size: CGFloat) -> some View {
        VStack(spacing: 16) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 18) {
                    ForEach(rows[row], id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: size, height: size)
                        } else {
                            Button {
                                if key == "delete" { deleteDigit() }
                                else { enterDigit(key) }
                            } label: {
                                if key == "delete" {
                                    Image(systemName: "delete.left")
                                        .font(.system(size: 27, weight: .light))
                                        .foregroundStyle(.white.opacity(0.7))
                                } else {
                                    Text(key)
                                        .font(.system(size: 35, weight: .light))
                                }
                            }
                            .buttonStyle(PasscodeKeyStyle(size: size))
                            .accessibilityLabel(key == "delete" ? "Delete digit" : key)
                            .disabled(isPairing)
                        }
                    }
                }
            }
        }
    }

    private func enterDigit(_ digit: String) {
        guard !isPairing, code.count < 5 else { return }
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        errorMessage = nil
        code += digit
        if code.count == 5 { pair() }
    }

    private func deleteDigit() {
        guard !isPairing, !code.isEmpty else { return }
        if hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
        code.removeLast()
        errorMessage = nil
    }

    private func pasteCode() {
        guard !isPairing,
              let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              pasted.utf8.count == 5,
              pasted.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            errorMessage = "Copy a five-digit code from Stats Companion."
            if hapticsEnabled { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            return
        }
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        code = pasted
        errorMessage = nil
        pair()
    }

    private func pair() {
        isPairing = true
        let name = String(UIDevice.current.name.prefix(60))
        store.pairWithPasscode(device, code: code, phoneName: name.isEmpty ? "iPhone" : name) { result in
            isPairing = false
            switch result {
            case .success:
                if hapticsEnabled { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                dismiss()
                onPaired()
            case .failure(let error):
                code = ""
                errorMessage = error.localizedDescription
                if hapticsEnabled { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            }
        }
    }
}

private struct PasscodeKeyStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom),
                in: Circle()
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
