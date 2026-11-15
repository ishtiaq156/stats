import AppKit
import Combine
import SwiftUI

/// MenuBarExtra snapshots its SwiftUI label on some macOS versions. Own the
/// native status item so update checks can replace the button image directly.
@MainActor
final class CompanionStatusItemController: NSObject {
    private(set) var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var hasUpdate = false
    private var started = false

    func start(model: StatsCompanionModel,
               openSettings: @escaping (CompanionSettingsPage) -> Void) {
        guard !started else { return }
        started = true
        hasUpdate = model.hasUpdateAvailable

        let hostingController = NSHostingController(rootView: CompanionMenu(
            model: model, openSettingsAction: openSettings
        ))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient

        setVisible(model.menuBarVisible)
        model.$menuBarVisible
            .dropFirst()
            .sink { [weak self] visible in self?.setVisible(visible) }
            .store(in: &subscriptions)
        model.$updateState
            .dropFirst()
            .sink { [weak self] state in
                let available: Bool
                if case .available = state { available = true } else { available = false }
                guard let self, self.hasUpdate != available else { return }
                self.hasUpdate = available
                self.updateButtonImage()
            }
            .store(in: &subscriptions)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            statusItem = item
            updateButtonImage()
        } else if let statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func updateButtonImage() {
        guard let button = statusItem?.button else { return }
        button.image = Self.image(hasUpdate: hasUpdate)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = hasUpdate ? "Stats Companion, update available" : "Stats Companion"
        button.setAccessibilityLabel(button.toolTip)
    }

    static func image(hasUpdate: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: hasUpdate ? 28 : 18, height: 18), flipped: false) { _ in
            NSImage(named: "StatsStatusMark")?.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            if hasUpdate {
                NSImage(named: "StatsUpdateAvailable")?.draw(
                    in: NSRect(x: 15, y: 2.5, width: 13, height: 13)
                )
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
