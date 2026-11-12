import AppKit
import Foundation
import SwiftUI

// A lightweight model stub compiles the production menu bar label without
// starting MetricServer, touching Keychain, or launching Stats Companion.
@MainActor
final class StatsCompanionModel: ObservableObject {
    @Published var hasUpdateAvailable = false
}

@main
struct MenuBarLabelTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, filename) in [
            ("StatsStatusMark", "StatsStatusMark.imageset/StatsStatusMark@2x.png"),
            ("StatsUpdateAvailable", "StatsUpdateAvailable.imageset/update-available@2x.png")
        ] {
            let file = root.appendingPathComponent(filename).path
            guard let image = NSImage(contentsOfFile: file),
                  image.tiffRepresentation != nil else {
                fatalError("Missing menu bar image: \(file)")
            }
            image.setName(NSImage.Name(name))
        }

        let model = StatsCompanionModel()
        let hostingView = NSHostingView(rootView: CompanionMenuBarLabel(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView

        func measuredWidth() -> CGFloat {
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.fittingSize.width
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let normal = measuredWidth()
        model.hasUpdateAvailable = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let update = measuredWidth()
        model.hasUpdateAvailable = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let restored = measuredWidth()

        // MenuBarExtra can retain the initial NSStatusItem width even when
        // the SwiftUI label's intrinsic width grows. Keep the icon slot fixed
        // in all states so a newly available update cannot be clipped.
        precondition(abs(normal - 35) < 1, "Reserved status icon width: \(normal)")
        precondition(abs(update - normal) < 1, "Update changed status item width: \(update)")
        precondition(abs(restored - normal) < 1, "Reset changed status item width: \(restored)")
        print("Menu bar label: stable width \(normal) → \(update) → \(restored) points")
    }
}
