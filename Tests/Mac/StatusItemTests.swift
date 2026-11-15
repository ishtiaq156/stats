import AppKit
import Combine
import SwiftUI

enum CompanionSettingsPage { case home }
enum CompanionUpdateState { case idle, available }

@MainActor
final class StatsCompanionModel: ObservableObject {
    @Published var updateState: CompanionUpdateState = .idle
    @Published var menuBarVisible = true
    var hasUpdateAvailable: Bool {
        if case .available = updateState { return true }
        return false
    }
}

struct CompanionMenu: View {
    let model: StatsCompanionModel
    let openSettingsAction: (CompanionSettingsPage) -> Void
    var body: some View { Text("Menu") }
}

@main
struct MenuBarLabelTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, filename) in [
            ("StatsStatusMark", "StatsStatusMark.imageset/StatsStatusMark@2x.png"),
            ("StatsUpdateAvailable", "StatsUpdateAvailable.imageset/update-available@2x.png")
        ] {
            let file = root.appendingPathComponent(filename).path
            guard let image = NSImage(contentsOfFile: file), image.setName(NSImage.Name(name)) else {
                fatalError("Missing menu bar image: \(file)")
            }
        }

        let model = StatsCompanionModel()
        let controller = CompanionStatusItemController()
        controller.start(model: model) { _ in }
        let initialButton = controller.statusItem?.button
        precondition(initialButton != nil, "Status item was not created")
        precondition(initialButton?.image?.size.width == 18,
                     "Normal icon reserves update badge space")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let normalButtonWidth = initialButton?.bounds.width ?? 0
        let normal = badgePixels(in: initialButton!.image)

        model.updateState = .available
        let updateButton = controller.statusItem?.button
        precondition(updateButton === initialButton, "Status item was recreated")
        precondition(updateButton?.image?.size.width == 28,
                     "Update icon did not expand for the badge")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let updateButtonWidth = updateButton?.bounds.width ?? 0
        let available = badgePixels(in: updateButton?.image)
        precondition(normal == 0 && available > 0,
                     "Update badge did not appear in native status button: \(normal) → \(available)")
        precondition(updateButton?.toolTip == "Stats Companion, update available")

        model.updateState = .idle
        precondition(controller.statusItem?.button?.image?.size.width == 18,
                     "Normal icon did not shrink after update cleared")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let restoredButtonWidth = controller.statusItem?.button?.bounds.width ?? 0
        precondition(updateButtonWidth - normalButtonWidth >= 9,
                     "Native status item did not widen for the arrow")
        precondition(abs(restoredButtonWidth - normalButtonWidth) < 1,
                     "Native status item kept empty arrow space")
        precondition(badgePixels(in: controller.statusItem?.button?.image) == 0,
                     "Update badge did not clear")
        model.menuBarVisible = false
        precondition(controller.statusItem == nil, "Hidden status item remained")
        model.menuBarVisible = true
        precondition(controller.statusItem?.button != nil, "Status item did not return")
        print("Native menu bar button widths: \(normalButtonWidth) → \(updateButtonWidth) → \(restoredButtonWidth)")
    }

    @MainActor
    private static func badgePixels(in image: NSImage?) -> Int {
        guard let image, let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return 0 }
        guard image.size.width > 18 else { return 0 }
        let start = Int(Double(bitmap.pixelsWide) * 19 / image.size.width)
        return (start..<bitmap.pixelsWide).reduce(0) { sum, x in
            sum + (0..<bitmap.pixelsHigh).reduce(0) { row, y in
                row + ((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 ? 1 : 0)
            }
        }
    }
}
