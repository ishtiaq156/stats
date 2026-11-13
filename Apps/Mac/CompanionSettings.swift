import AppKit
import SwiftUI

struct CompanionSettings: View {
    @ObservedObject var model: StatsCompanionModel
    @State private var copiedPasscode = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var phoneToRevoke: PairedPhone?
    @State private var phoneToRename: PairedPhone?
    @State private var showingConnectionAddress = false
    @State private var keyboardNavigationActive = false
    @FocusState private var settingsFocus: SettingsFocus?

    private enum SettingsFocus: Hashable {
        case copyPasscode, refreshPasscode, connectionAddress, wifiLocation, updates
        case website, about, changelog, dock, menuBar, login
        case quit, feedback, changelogBack
        case pairedPhones, pairedPhonesBack, rename(UUID), revoke(UUID)
    }

    private var homeFocusOrder: [SettingsFocus] {
        var actions: [SettingsFocus] = []
        if model.pairingCode != nil {
            actions += [.refreshPasscode, .copyPasscode]
        } else if model.pairingLocked {
            actions.append(.refreshPasscode)
        }
        if model.localAddress != nil { actions.append(.connectionAddress) }
        if model.needsWiFiLocationAccess { actions.append(.wifiLocation) }
        switch model.installationState {
        case .downloading, .ready, .failed:
            actions.append(.updates)
        case .installing:
            break
        case .idle:
            switch model.updateState {
            case .idle, .available, .failed: actions.append(.updates)
            case .checking, .upToDate: break
            }
        }
        actions += [.website, .about, .changelog]
        if !(model.dockVisible && !model.menuBarVisible) { actions.append(.dock) }
        if !(model.menuBarVisible && !model.dockVisible) { actions.append(.menuBar) }
        actions.append(.login)
        if !model.pairedPhones.isEmpty { actions.append(.pairedPhones) }
        actions += [.quit, .feedback]
        return actions
    }

    private var pageFocusOrder: [SettingsFocus] {
        switch model.settingsPage {
        case .home: homeFocusOrder
        case .changelog: [.changelogBack]
        case .pairedPhones:
            [.pairedPhonesBack] + model.pairedPhones.flatMap { [.rename($0.id), .revoke($0.id)] }
        }
    }

    private func moveSettingsFocus(backward: Bool) {
        let actions = pageFocusOrder
        guard !actions.isEmpty else { return }
        guard let settingsFocus, let index = actions.firstIndex(of: settingsFocus) else {
            self.settingsFocus = backward ? actions.last : actions.first
            return
        }
        let next = (index + (backward ? -1 : 1) + actions.count) % actions.count
        self.settingsFocus = actions[next]
    }

    /// Return and Space follow the same focus order as Tab, even when macOS
    /// doesn't designate an individual plain-style button as the default.
    /// Pointer, VoiceOver, and native button actions remain unchanged.
    private func activateFocusedSetting() -> Bool {
        let actions = pageFocusOrder
        guard keyboardNavigationActive,
              !showingConnectionAddress, phoneToRevoke == nil, phoneToRename == nil,
              let focus = settingsFocus, actions.contains(focus) else { return false }

        switch focus {
        case .refreshPasscode:
            refreshPasscode()
        case .copyPasscode:
            guard let code = model.pairingCode else { return false }
            copyPasscode(code)
        case .connectionAddress:
            showingConnectionAddress = true
        case .wifiLocation:
            model.requestWiFiLocationAccess()
        case .updates:
            switch model.installationState {
            case .downloading: model.cancelUpdateDownload()
            case .ready: model.installUpdate()
            case .installing: return false
            case .failed:
                if model.hasDownloadedInstaller { model.installUpdate() }
                else { model.downloadUpdate() }
            case .idle:
                if case .available = model.updateState { model.downloadUpdate() }
                else { model.checkForUpdates() }
            }
        case .website:
            open("https://github.com/ishtiaq156/stats")
        case .about:
            showAbout()
        case .changelog:
            model.settingsPage = .changelog
        case .pairedPhones:
            model.settingsPage = .pairedPhones
        case .dock:
            model.setDockVisible(!model.dockVisible)
        case .menuBar:
            model.setMenuBarVisible(!model.menuBarVisible)
        case .login:
            model.setOpenAtLogin(!model.openAtLogin)
        case .quit:
            NSApp.terminate(nil)
        case .feedback:
            open("https://github.com/ishtiaq156/stats/issues/new")
        case .changelogBack:
            model.settingsPage = .home
        case .pairedPhonesBack:
            model.settingsPage = .home
        case .rename(let id):
            guard let phone = model.pairedPhones.first(where: { $0.id == id }) else { return false }
            phoneToRename = phone
        case .revoke(let id):
            guard let phone = model.pairedPhones.first(where: { $0.id == id }) else { return false }
            phoneToRevoke = phone
        }
        return true
    }

    var body: some View {
        Group {
            switch model.settingsPage {
            case .home: settingsHome
            case .changelog: changelogPage
            case .pairedPhones: pairedPhonesPage
            }
        }
        // The native titlebar adds roughly 28 points to the content height.
        .frame(width: 460, height: min(645, max(420, (NSScreen.main?.visibleFrame.height ?? 673) - 28)))
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        .background(.regularMaterial)
        .background(SettingsWindowConfigurator())
        .background(CompanionTabNavigation(
            onTab: { backward in
                guard !showingConnectionAddress, phoneToRevoke == nil, phoneToRename == nil else { return false }
                keyboardNavigationActive = true
                moveSettingsFocus(backward: backward)
                return true
            },
            onActivate: { activateFocusedSetting() },
            onPointer: {
                // Match native keyboard-versus-pointer focus presentation:
                // mouse interaction keeps control functionality, but clears
                // the tab-navigation ring until the next Tab/Shift-Tab.
                keyboardNavigationActive = false
                settingsFocus = nil
            }
        ))
        .onAppear {
            keyboardNavigationActive = false
            settingsFocus = nil
        }
        .onChange(of: model.settingsPage) { _, page in
            guard keyboardNavigationActive else { settingsFocus = nil; return }
            switch page {
            case .home: settingsFocus = .changelog
            case .changelog: settingsFocus = .changelogBack
            case .pairedPhones: settingsFocus = .pairedPhonesBack
            }
        }
        .sheet(item: $phoneToRename) { phone in
            RenamePairedPhoneSheet(phone: phone) { name in
                model.renamePhone(phone.id, to: name)
            }
        }
        .alert("Revoke phone access?", isPresented: Binding(
            get: { phoneToRevoke != nil },
            set: { if !$0 { phoneToRevoke = nil } }
        )) {
            Button("Cancel", role: .cancel) { phoneToRevoke = nil }
            Button("Revoke", role: .destructive) {
                if let phoneToRevoke { model.revokePhone(phoneToRevoke.id) }
                phoneToRevoke = nil
            }
        } message: {
            Text("This phone will need to pair again before it can read your Mac's stats.")
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            keyboardNavigationActive = false
            settingsFocus = nil
        }
    }

    private var settingsHome: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    passcodeHeader
                        .padding(.bottom, 18)

                    card {
                        networkStatusRow
                        connectionStatusRow
                    }

                    if model.needsWiFiLocationAccess {
                        card {
                            actionRow(model.wifiLocationAuthorization == .notDetermined
                                      ? "Allow Wi-Fi network name" : "Open Location Settings",
                                      symbol: "location.circle", height: 46) {
                                model.requestWiFiLocationAccess()
                            }
                            .help("Location permission lets Stats Companion show the connected Wi-Fi name. No location is collected.")
                            .focused($settingsFocus, equals: .wifiLocation)
                        }
                    }

                    card {
                        updateRow
                        cardDivider
                        actionRow("Website") {
                            open("https://github.com/ishtiaq156/stats")
                        }
                        .focused($settingsFocus, equals: .website)
                        cardDivider
                        actionRow("About") { showAbout() }
                            .focused($settingsFocus, equals: .about)
                    }

                    card {
                        actionRow("Changelog", symbol: "chevron.right", height: 50) {
                            model.settingsPage = .changelog
                        }
                        .focused($settingsFocus, equals: .changelog)
                    }

                    card {
                        settingsToggle(
                            "Dock",
                            detail: "Show Stats Companion in the Dock alongside other apps",
                            isOn: Binding(get: { model.dockVisible }, set: { model.setDockVisible($0) }),
                            disabled: model.dockVisible && !model.menuBarVisible,
                            focus: .dock
                        )
                        cardDivider
                        settingsToggle(
                            "Menu Bar",
                            detail: "Keep Stats in the Dock when this is off",
                            isOn: Binding(get: { model.menuBarVisible }, set: { model.setMenuBarVisible($0) }),
                            disabled: model.menuBarVisible && !model.dockVisible,
                            focus: .menuBar
                        )
                        cardDivider
                        settingsToggle(
                            "Open at login",
                            detail: nil,
                            isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }),
                            disabled: false,
                            focus: .login
                        )
                    }
                    if let error = model.visibilityError ?? model.loginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    }

                    if !model.pairedPhones.isEmpty {
                        card {
                            actionRow("Paired phones (\(model.pairedPhones.count))",
                                      symbol: "chevron.right", height: 50) {
                                model.settingsPage = .pairedPhones
                            }
                            .focused($settingsFocus, equals: .pairedPhones)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)

            settingsFooter
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 13)
        }
    }

    private var passcodeHeader: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Text("Passcode")
                if let expiry = model.pairingExpires {
                    Text("·")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(expiry.timeIntervalSince(context.date)))
                        Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let code = model.pairingCode {
                    Text(code)
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                    Button {
                        refreshPasscode()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 17, height: 17)
                    }
                    .companionGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .help("Refresh passcode")
                    .accessibilityLabel("Refresh passcode")
                    .focusable()
                    .focusEffectDisabled(!keyboardNavigationActive)
                    .focused($settingsFocus, equals: .refreshPasscode)
                    Button {
                        copyPasscode(code)
                    } label: {
                        Image(systemName: copiedPasscode ? "checkmark" : "document.on.document")
                            .frame(width: 17, height: 17)
                    }
                    .companionGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .help(copiedPasscode ? "Passcode copied" : "Copy passcode")
                    .accessibilityLabel(copiedPasscode ? "Passcode copied" : "Copy passcode")
                    .focusable()
                    .focusEffectDisabled(!keyboardNavigationActive)
                    .focused($settingsFocus, equals: .copyPasscode)
                } else if model.pairingLocked {
                    Text("Pairing paused")
                        .font(.headline)
                    Button("New code") { refreshPasscode() }
                        .companionGlassButtonStyle()
                        .focusable()
                        .focusEffectDisabled(!keyboardNavigationActive)
                        .focused($settingsFocus, equals: .refreshPasscode)
                } else {
                    Text("Generating passcode…")
                        .foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsFooter: some View {
        HStack {
            Button("Quit Stats Companion") { NSApp.terminate(nil) }
                .font(.system(size: 12, weight: .medium))
                .companionGlassButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .focusable()
                .focusEffectDisabled(!keyboardNavigationActive)
                .focused($settingsFocus, equals: .quit)

            Spacer()

            Button("Feedback & Support") {
                open("https://github.com/ishtiaq156/stats/issues/new")
            }
            .font(.system(size: 12, weight: .semibold))
            .companionGlassButtonStyle(prominent: true)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.blue)
            .focusable()
            .focusEffectDisabled(!keyboardNavigationActive)
            .focused($settingsFocus, equals: .feedback)
        }
    }

    private var networkStatusRow: some View {
        let network = CompanionConnectionPresentation.network(model)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: network.symbol)
                .foregroundStyle(network.color)
                .font(.system(size: 21))
                .frame(width: 22)
            Text(network.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let address = model.localAddress {
                Button {
                    showingConnectionAddress = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Manual connection address")
                .accessibilityLabel("Show manual connection address")
                .focusable()
                .focusEffectDisabled(!keyboardNavigationActive)
                .focused($settingsFocus, equals: .connectionAddress)
                .popover(isPresented: $showingConnectionAddress, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Manual connection")
                            .font(.headline)
                        Text("Use this address if your iPhone cannot find the Mac automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                                showingConnectionAddress = false
                            } label: {
                                Image(systemName: "document.on.document")
                                    .frame(width: 17, height: 17)
                            }
                            .companionGlassButtonStyle()
                            .buttonBorderShape(.circle)
                            .controlSize(.regular)
                            .accessibilityLabel("Copy manual connection address")
                            .help("Copy address")
                        }
                    }
                    .padding(16)
                    .frame(width: 265, alignment: .leading)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var connectionStatusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            let active = model.pairedPhones.filter(\.isConnected)
            Image(systemName: active.isEmpty ? CompanionConnectionPresentation.noDevices.symbol : "iphone.circle.fill")
                .foregroundStyle(active.isEmpty ? CompanionConnectionPresentation.noDevices.color : Color.green)
                .font(.system(size: 21))
                .frame(width: 22)
            Text(active.isEmpty ? "No devices connected" : active.map(\.name).joined(separator: ", "))
                .foregroundStyle(active.isEmpty ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var updateRow: some View {
        Group {
            switch model.installationState {
            case .downloading(let progress):
                actionRow(progress.map { "Downloading… \(Int($0 * 100))% · Cancel" }
                          ?? "Downloading… · Cancel", symbol: "xmark.circle") {
                    model.cancelUpdateDownload()
                }.focused($settingsFocus, equals: .updates)
            case .ready:
                actionRow("Install update & Restart", symbol: "arrow.clockwise") {
                    model.installUpdate()
                }.focused($settingsFocus, equals: .updates)
            case .installing:
                statusActionRow("Preparing to restart…", spinner: true)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 0) {
                    actionRow(model.hasDownloadedInstaller ? "Retry install" : "Retry download",
                              symbol: "arrow.clockwise") {
                        if model.hasDownloadedInstaller { model.installUpdate() }
                        else { model.downloadUpdate() }
                    }.focused($settingsFocus, equals: .updates)
                    Text(message).font(.system(size: 11)).foregroundStyle(.red)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                    if model.hasDownloadedInstaller {
                        actionRow("Open downloaded installer", symbol: "folder") {
                            model.openDownloadedInstaller()
                        }
                    }
                }
            case .idle:
                switch model.updateState {
                case .idle:
                    actionRow("Check for updates") { model.checkForUpdates() }
                        .focused($settingsFocus, equals: .updates)
                case .checking:
                    statusActionRow("Checking…", spinner: true)
                case .upToDate:
                    statusActionRow("Up to date", symbol: "checkmark")
                case .available(let release):
                    actionRow("Download version \(release.version)", symbol: "arrow.down.circle") {
                        model.downloadUpdate()
                    }.focused($settingsFocus, equals: .updates)
                case .failed:
                    actionRow("Couldn’t check · Retry", symbol: "exclamationmark.circle") {
                        model.checkForUpdates()
                    }.focused($settingsFocus, equals: .updates)
                }
            }
        }
    }

    private var pairedPhonesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.pairedPhones.isEmpty {
                    Text("No phones paired yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    Text("Rename a phone to recognize it on this Mac, or revoke its access.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                    card {
                        ForEach(model.pairedPhones) { phone in
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: phone.isConnected ? "iphone.circle.fill" : "iphone")
                                    .font(.system(size: 17))
                                    .foregroundStyle(phone.isConnected ? Color.green : Color.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(phone.name)
                                        .font(.system(size: 13))
                                        .lineLimit(2)
                                    Text(phone.isConnected ? "Connected" :
                                         (phone.lastSeen.map { "Last active \($0.formatted())" } ?? "Never active"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Rename") { phoneToRename = phone }
                                    .buttonStyle(.bordered)
                                    .focusable()
                                    .focusEffectDisabled(!keyboardNavigationActive)
                                    .focused($settingsFocus, equals: .rename(phone.id))
                                Button("Revoke", role: .destructive) { phoneToRevoke = phone }
                                    .buttonStyle(.bordered)
                                    .focusable()
                                    .focusEffectDisabled(!keyboardNavigationActive)
                                    .focused($settingsFocus, equals: .revoke(phone.id))
                            }
                            .padding(10)
                            if phone.id != model.pairedPhones.last?.id { cardDivider }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
        .companionSoftScrollEdge {
            ZStack {
                Text("Paired phones")
                    .font(.system(size: 34, weight: .bold))
                HStack {
                    Button { model.settingsPage = .home } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .companionGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("Back to Settings")
                    .help("Back to Settings")
                    .focusable()
                    .focusEffectDisabled(!keyboardNavigationActive)
                    .focused($settingsFocus, equals: .pairedPhonesBack)
                    Spacer()
                }
                .padding(.leading, 20)
            }
            .frame(height: 45)
            .padding(.top, 43)
            .padding(.bottom, 18)
        }
    }

    private var changelogPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                ForEach(CompanionRelease.notes) { release in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stats Companion \(release.version)")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 7) {
                            Image(systemName: "calendar")
                                .foregroundStyle(.red)
                            Text(release.date)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(release.changes, id: \.self) { change in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("•")
                                    Text(change)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 25)
        }
        .scrollIndicators(.automatic)
        .companionSoftScrollEdge {
            ZStack {
                Text("Changelog")
                    .font(.system(size: 34, weight: .bold))
                HStack {
                    Button {
                        model.settingsPage = .home
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .companionGlassButtonStyle()
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("Back to Settings")
                    .help("Back to Settings")
                    .focusable()
                    .focusEffectDisabled(!keyboardNavigationActive)
                    .focused($settingsFocus, equals: .changelogBack)
                    Spacer()
                }
                .padding(.leading, 20)
            }
            .frame(height: 45)
            .padding(.top, 43)
            .padding(.bottom, 18)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .labelColor).opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 12))
    }

    private var cardDivider: some View {
        Divider().padding(.leading, 10).padding(.trailing, 10)
    }

    private func actionRow(_ title: String, symbol: String? = nil, height: CGFloat = 42,
                           action: @escaping () -> Void) -> some View {
        SettingsActionRow(title: title, symbol: symbol, height: height,
                          showsKeyboardFocus: keyboardNavigationActive, action: action)
    }

    private func statusActionRow(_ title: String, symbol: String? = nil,
                                 spinner: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            if spinner {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    private func settingsToggle(_ title: String, detail: String?,
                                isOn: Binding<Bool>, disabled: Bool,
                                focus: SettingsFocus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
                .accessibilityLabel(title)
                .focusable(!disabled)
                .focusEffectDisabled(!keyboardNavigationActive)
                .focused($settingsFocus, equals: focus)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: detail == nil ? 43 : 52)
    }

    private func showAbout() {
        CompanionAboutWindow.show()
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyPasscode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copiedPasscode = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            copiedPasscode = false
        }
    }

    private func refreshPasscode() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copiedPasscode = false
        model.refreshPasscode()
    }
}

private struct RenamePairedPhoneSheet: View {
    let phone: PairedPhone
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String

    init(phone: PairedPhone, onSave: @escaping (String) -> Void) {
        self.phone = phone
        self.onSave = onSave
        _name = State(initialValue: phone.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename phone")
                .font(.headline)
            Text("Choose the name shown for this phone in Stats Companion.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Phone name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedName.count > 60)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty, trimmedName.count <= 60 else { return }
        onSave(trimmedName)
        dismiss()
    }
}

private extension View {
    @ViewBuilder
    func companionSoftScrollEdge<Bar: View>(@ViewBuilder bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }

    @ViewBuilder
    func companionGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

@MainActor
enum CompanionAboutWindow {
    private static var aboutWindow: NSWindow?

    static func show() {
        if let aboutWindow {
            NSApp.activate(ignoringOtherApps: true)
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 280, height: 232)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About Stats Companion"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSHostingView(rootView: CompanionAboutContent())
        window.setContentSize(size)
        window.center()
        aboutWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct CompanionAboutContent: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.2"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5"

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 22)

            Image("StatsBrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)

            Text("Stats Companion")
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 10)
            Text("Version \(version) (\(build))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Text("© 2026 Ishtiaq Ul Haq Syed.")
                .padding(.top, 14)
            Text("All Rights Reserved.")
                .padding(.top, 2)

            Spacer(minLength: 18)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: 280, height: 232)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsActionRow: View {
    let title: String
    let symbol: String?
    let height: CGFloat
    let showsKeyboardFocus: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(hovered ? Color.primary.opacity(0.055) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled(!showsKeyboardFocus)
        .onHover { hovered = $0 }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

private struct CompanionRelease: Identifiable {
    let version: String
    let date: String
    let changes: [String]
    var id: String { version }

    static let notes: [CompanionRelease] = [
        .init(version: "0.3.11", date: "November 13, 2026", changes: [
            "Find Mac updates in combined iPhone and Companion releases when the GitHub tag and Mac app version differ."
        ]),
        .init(version: "0.3.10", date: "November 13, 2026", changes: [
            "Let iPhone Disk settings show or hide removable volumes, including mounted disk images."
        ]),
        .init(version: "0.3.9", date: "November 11, 2026", changes: [
            "Center connected-phone icons vertically with their names in the menu bar, matching the Settings screen."
        ]),
        .init(version: "0.3.8", date: "November 11, 2026", changes: [
            "Download Mac updates with progress directly from the menu bar.",
            "Verify the release checksum and app signature before offering Install & Restart.",
            "Install in place and relaunch automatically, with retry and a manual installer fallback.",
            "Restart Stats Companion directly from the menu bar."
        ]),
        .init(version: "0.3.7", date: "November 11, 2026", changes: [
            "Reserve space for the menu bar update arrow before the first update check so macOS cannot clip it when a newer release becomes available."
        ]),
        .init(version: "0.3.6", date: "November 11, 2026", changes: [
            "Moved paired phones into a dedicated, scrollable Settings page.",
            "Added phone renaming without requiring a new pairing, while preserving individual revocation."
        ]),
        .init(version: "0.3.5", date: "November 11, 2026", changes: [
            "Keep the menu bar's update arrow synchronized with release checks, without reopening the app.",
            "Preserve the blue Stats icon and the circular update arrow in both light and dark appearances."
        ]),
        .init(version: "0.3.4", date: "November 11, 2026", changes: [
            "Retry local Bonjour discovery automatically after a temporary publishing failure or first-run permission change.",
            "Show the Bonjour error code when discovery fails, while keeping manual address pairing available."
        ]),
        .init(version: "0.3.3", date: "November 11, 2026", changes: [
            "Show a circular up-arrow beside the Stats menu bar icon when a newer Mac version is available.",
            "Check for new releases quietly at launch and every six hours, including pre-releases.",
            "Keep an available update visible if a later network check temporarily fails.",
            "Update repository and support links following the move to the Stats project."
        ]),
        .init(version: "0.3.2", date: "October 30, 2026", changes: [
            "Reworked the Mac Settings window around the passcode, connection status, actions, and visibility controls.",
            "Refined compact menu spacing, typography, glass controls, and passcode copy and refresh feedback.",
            "Added Tab and Shift-Tab navigation to the menu and Settings, with keyboard-focus highlighting that clears after pointer input.",
            "Applied the original blue chart artwork to the Mac menu bar and Dock and the iPhone app icon.",
            "Added a copy icon beside the manual connection address and aligned the Changelog title with the system font.",
            "Used native macOS scroll-edge fading for Changelog and fixed a menu bar visibility update loop.",
            "Kept the familiar Help menu lightbulb and showed the Stats icon in the native unavailable-Help alert.",
            "Clicking the running app's Dock icon now opens the Settings window."
        ]),
        .init(version: "0.3.1", date: "October 30, 2026", changes: [
            "Refined the menu with pointer and keyboard row highlights, a persistent passcode, and clearer network status.",
            "Added Dock and Menu Bar controls, a fuller Settings page, and an in-app changelog.",
            "Improved update check feedback and brought the About window to the front."
        ]),
        .init(version: "0.3.0", date: "October 30, 2026", changes: [
            "Replaced shared-key QR pairing with a temporary five-digit passcode and a separate credential for each phone.",
            "Added individual phone revocation and connected-device status.",
            "Added login startup, update checks, and a port 8888 fallback."
        ]),
        .init(version: "0.2.0", date: "October 29, 2026", changes: [
            "Added recent activity charts for CPU, memory, storage, and network.",
            "The iPhone remembers the last paired Mac."
        ]),
        .init(version: "0.1.0", date: "October 29, 2026", changes: [
            "Introduced the Mac sampler, local discovery, encrypted snapshots, and the iPhone overview."
        ])
    ]
}
