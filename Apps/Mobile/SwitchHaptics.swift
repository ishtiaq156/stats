import CoreHaptics
import SwiftUI
import UIKit

@MainActor
private final class SwitchFeedback {
    static let shared = SwitchFeedback()

    private var engine: CHHapticEngine?
    private let fallback = UISelectionFeedbackGenerator()

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
    }

    func changed() {
        if let engine {
            do {
                let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                ], relativeTime: 0)
                try engine.start()
                try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: 0)
                return
            } catch { }
        }
        fallback.selectionChanged()
        fallback.prepare()
    }
}

struct HapticToggle: View {
    let title: String
    @Binding var isOn: Bool
    var controlsHaptics = false
    @AppStorage(StatsHapticPreference.enabledKey) private var hapticsEnabled = true

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { enabled in
                let playFeedback = hapticsEnabled || (controlsHaptics && enabled)
                isOn = enabled
                if playFeedback { SwitchFeedback.shared.changed() }
            }
        ))
    }
}
