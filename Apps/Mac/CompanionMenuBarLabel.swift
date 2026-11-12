import SwiftUI

/// A scene's body does not observe changes to the model merely because it
/// owns the model as a StateObject. The menu bar label must subscribe itself.
/// Also reserve the update icon's space up front: the native status-bar item
/// may cache its first intrinsic width and clip an icon added later.
@MainActor
struct CompanionMenuBarLabel: View {
    @ObservedObject var model: StatsCompanionModel

    var body: some View {
        HStack(spacing: 2) {
            Image("StatsStatusMark")
                .resizable()
                .interpolation(.high)
                .renderingMode(.original)
                .frame(width: 18, height: 18)
            if model.hasUpdateAvailable {
                Image("StatsUpdateAvailable")
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.original)
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 35, height: 18)
        .accessibilityLabel(model.hasUpdateAvailable ? "Stats Companion, update available" : "Stats Companion")
    }
}
