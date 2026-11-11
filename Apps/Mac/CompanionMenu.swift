import AppKit
import SwiftUI

private enum MenuAction {
    case copyPasscode
    case refreshPasscode
    case checkUpdates
    case website
    case about
    case changelog
    case openAtLogin
    case settings
    case quit
}

/// One presentation model for both the status menu and the Settings window.
/// A missing phone is informational; only a failed listener is an error.
enum CompanionConnectionPresentation {
    struct Status {
        let text: String
        let symbol: String
        let color: Color
    }

    @MainActor
    static func network(_ model: StatsCompanionModel) -> Status {
        if model.isDiscoverable {
            let text = model.port.map { "Discoverable on the network using port \($0)" }
                ?? "Discoverable on the network"
            return Status(text: text, symbol: "checkmark.circle.fill", color: .green)
        }
        if let error = model.networkError, !error.isEmpty {
            return Status(text: error, symbol: "xmark.circle.fill", color: .red)
        }
        return Status(text: "Starting connection service…", symbol: "ellipsis.circle.fill", color: .secondary)
    }

    static let noDevices = Status(text: "No devices connected", symbol: "exclamationmark.circle.fill", color: .yellow)
}

struct CompanionMenu: View {
    @ObservedObject var model: StatsCompanionModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var menuFocused: Bool
    @State private var keyboardSelection: MenuAction?
    @State private var hoveredAction: MenuAction?
    @State private var copiedPasscode = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            passcodeSection
            menuDivider
            statusSection
            menuDivider
            updateRow
            row("Website", action: .website)
            row("About", action: .about)
            menuDivider
            row("Changelog", action: .changelog)
            menuDivider
            CompanionToggleRow(
                title: "Open at login",
                isOn: Binding(
                    get: { model.openAtLogin },
                    set: {
                        keyboardSelection = nil
                        model.setOpenAtLogin($0)
                    }
                ),
                keyboardSelected: keyboardSelection == .openAtLogin,
                onHover: { hovering in
                    if hovering {
                        hoveredAction = nil
                        keyboardSelection = nil
                    }
                }
            )
            if let error = model.loginError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            row("Settings", action: .settings, shortcut: "⌘,")
            menuDivider
            row("Quit Stats Companion", action: .quit, shortcut: "⌘Q")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 312)
        .background(CompanionTabNavigation(
            onTab: { backward in
                moveSelection(backward ? -1 : 1)
                // Restore root arrow/Escape handling after clicking a control.
                menuFocused = true
                return true
            },
            onActivate: {
                // Activation follows the highlighted row even if a native
                // switch/button briefly retained first-responder focus.
                activateSelection() == .handled
            }
        ))
        .focusable()
        .focused($menuFocused)
        .focusEffectDisabled()
        .onAppear {
            DispatchQueue.main.async { menuFocused = true }
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(-1)
            case .down: moveSelection(1)
            default: break
            }
        }
        .onKeyPress(.return) {
            activateSelection()
        }
        .onKeyPress(.space) {
            activateSelection()
        }
        .onKeyPress(.escape) {
            keyboardSelection = nil
            return .handled
        }
    }

    private var passcodeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Passcode")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let expiry = model.pairingExpires {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(expiry.timeIntervalSince(context.date)))
                        Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if let code = model.pairingCode {
                    Text(code)
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Spacer()
                    refreshPasscodeButton
                    CompanionRow(
                        title: copiedPasscode ? "Copied" : "Copy passcode",
                        symbol: copiedPasscode ? "checkmark" : "text.document.fill",
                        iconOnly: true,
                        highlighted: highlighted(.copyPasscode),
                        onHover: { setHover(.copyPasscode, $0) }
                    ) {
                        keyboardSelection = nil
                        perform(.copyPasscode)
                    }
                    .frame(width: 30)
                } else if model.pairingLocked {
                    Text("Pairing paused")
                        .font(.headline)
                    Spacer()
                    refreshPasscodeButton
                } else {
                    Text("Generating passcode…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .padding(.bottom, 7)
    }

    private var refreshPasscodeButton: some View {
        CompanionRow(
            title: "Refresh passcode",
            symbol: "arrow.clockwise",
            iconOnly: true,
            highlighted: highlighted(.refreshPasscode),
            onHover: { setHover(.refreshPasscode, $0) }
        ) {
            keyboardSelection = nil
            perform(.refreshPasscode)
        }
        .frame(width: 30)
    }

    private var statusSection: some View {
        let network = CompanionConnectionPresentation.network(model)
        return VStack(alignment: .leading, spacing: 8) {
            statusRow(network.symbol, color: network.color, text: network.text)
            let active = model.pairedPhones.filter(\.isConnected)
            if active.isEmpty {
                statusRow(CompanionConnectionPresentation.noDevices.symbol,
                          color: CompanionConnectionPresentation.noDevices.color,
                          text: CompanionConnectionPresentation.noDevices.text, muted: true)
            } else {
                ForEach(active) { phone in
                    statusRow("iphone.circle.fill", color: .green, text: phone.name)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(_ symbol: String, color: Color, text: String, muted: Bool = false) -> some View {
        HStack(alignment: muted ? .center : .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(muted ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var updateRow: some View {
        Group {
            switch model.updateState {
            case .idle:
                row("Check for updates", action: .checkUpdates)
            case .checking:
                CompanionRow(title: "Checking…", symbol: "progress",
                             highlighted: false, enabled: false, showsSpinner: true) {}
            case .upToDate:
                CompanionRow(title: "Up to date", symbol: "checkmark",
                             highlighted: false, enabled: false) {}
            case .available(let version, _):
                row("Update available", action: .checkUpdates, trailing: "v\(version)", symbol: "arrow.up.right")
            case .failed:
                row("Couldn’t check · Retry", action: .checkUpdates, symbol: "exclamationmark.circle")
            }
        }
    }

    private func row(_ title: String, action: MenuAction,
                     trailing: String? = nil, symbol: String? = nil, shortcut: String? = nil) -> some View {
        CompanionRow(
            title: title,
            symbol: symbol,
            trailing: shortcut ?? trailing,
            shortcutKey: action == .settings ? "," : action == .quit ? "q" : nil,
            highlighted: highlighted(action),
            onHover: { setHover(action, $0) }
        ) {
            keyboardSelection = nil
            perform(action)
        }
    }

    private var menuDivider: some View {
        Divider()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
    }

    private var navigableActions: [MenuAction] {
        var result: [MenuAction] = []
        if model.pairingCode != nil {
            result += [.refreshPasscode, .copyPasscode]
        } else if model.pairingLocked {
            result.append(.refreshPasscode)
        }
        if model.updateState != .checking && model.updateState != .upToDate {
            result.append(.checkUpdates)
        }
        result += [.website, .about, .changelog, .openAtLogin, .settings, .quit]
        return result
    }

    private func highlighted(_ action: MenuAction) -> Bool {
        hoveredAction == action || keyboardSelection == action
    }

    private func setHover(_ action: MenuAction, _ hovering: Bool) {
        if hovering {
            hoveredAction = action
            keyboardSelection = nil
        } else if hoveredAction == action {
            hoveredAction = nil
        }
    }

    private func moveSelection(_ delta: Int) {
        let actions = navigableActions
        guard !actions.isEmpty else { return }
        hoveredAction = nil
        if let current = keyboardSelection, let index = actions.firstIndex(of: current) {
            keyboardSelection = actions[(index + delta + actions.count) % actions.count]
        } else {
            keyboardSelection = delta > 0 ? actions[0] : actions[actions.count - 1]
        }
    }

    private func activateSelection() -> KeyPress.Result {
        guard let action = keyboardSelection else { return .ignored }
        perform(action)
        return .handled
    }

    private func perform(_ action: MenuAction) {
        switch action {
        case .copyPasscode:
            guard let code = model.pairingCode else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copiedPasscode = true
            copyFeedbackTask?.cancel()
            copyFeedbackTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
                copiedPasscode = false
            }
        case .refreshPasscode:
            copyFeedbackTask?.cancel()
            copiedPasscode = false
            model.refreshPasscode()
        case .checkUpdates:
            if case .available(_, let url) = model.updateState {
                NSWorkspace.shared.open(url)
            } else {
                model.checkForUpdates()
            }
        case .website:
            open("https://github.com/ishtiaq156/stats")
        case .about:
            CompanionAboutWindow.show()
        case .changelog:
            showSettings(.changelog)
        case .openAtLogin:
            model.setOpenAtLogin(!model.openAtLogin)
        case .settings:
            showSettings(.home)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func showSettings(_ page: CompanionSettingsPage) {
        model.settingsPage = page
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.title.localizedCaseInsensitiveContains("Settings") })?
                .orderFrontRegardless()
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct CompanionRow: View {
    let title: String
    var symbol: String?
    var trailing: String?
    var iconOnly = false
    var shortcutKey: KeyEquivalent?
    let highlighted: Bool
    var enabled = true
    var showsSpinner = false
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void

    @ViewBuilder var body: some View {
        if let shortcutKey {
            button.keyboardShortcut(shortcutKey, modifiers: .command)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !iconOnly {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(highlighted && enabled ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                if showsSpinner {
                    ProgressView().controlSize(.small)
                } else if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(highlighted && enabled ? Color(nsColor: .selectedMenuItemTextColor) : Color.secondary)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(highlighted && enabled ? Color(nsColor: .selectedMenuItemTextColor) : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26,
                   alignment: iconOnly ? .center : .leading)
            .padding(.horizontal, iconOnly ? 0 : 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted && enabled ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover(perform: onHover)
        .accessibilityLabel(title)
    }
}

private struct CompanionToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let keyboardSelected: Bool
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(keyboardSelected ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .onHover(perform: onHover)
    }
}
