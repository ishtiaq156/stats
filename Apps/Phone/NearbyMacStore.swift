import ActivityCore
import Foundation
import Network
import Security

@MainActor
private final class BonjourMacNameResolver: NSObject, @preconcurrency NetServiceDelegate {
    private let service: NetService
    private let onName: @MainActor (String) -> Void

    init(name: String, type: String, domain: String, onName: @escaping @MainActor (String) -> Void) {
        service = NetService(domain: domain, type: type.hasSuffix(".") ? type : type + ".", name: name)
        self.onName = onName
        super.init()
    }

    func start() {
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func stop() {
        service.stop()
        service.delegate = nil
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let record = sender.txtRecordData() { updateName(from: record) }
        sender.startMonitoring()
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        updateName(from: data)
    }

    private func updateName(from data: Data) {
        guard let nameData = NetService.dictionary(fromTXTRecord: data)["name"],
              let name = String(data: nameData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        onName(name)
    }
}

private struct CachedMacAbout: Codable {
    let fetchedAt: Date
    let info: MacAboutInfo
}

@MainActor
final class NearbyMacStore: ObservableObject {
    struct Device: Identifiable {
        let endpoint: NWEndpoint
        let name: String
        let displayName: String
        var id: String { name }

        init(endpoint: NWEndpoint, name: String, displayName: String? = nil) {
            self.endpoint = endpoint
            self.name = name
            self.displayName = displayName ?? name
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var snapshot: MetricSnapshot?
    @Published private(set) var history: [MetricSnapshot] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var selectedDisplayName: String?
    @Published private(set) var sessionActive = false
    @Published private(set) var selectedReachable = false
    @Published private(set) var status = "Looking for Macs"
    @Published private(set) var discoveryError: String?
    @Published private(set) var aboutInfo: MacAboutInfo?
    @Published private(set) var aboutError: String?
    @Published private(set) var refreshIntervalSeconds: Int
    private var aboutFetchedAt: Date?
    private var aboutLastAttemptAt: Date?
    private static let aboutCacheLifetime: TimeInterval = 60 * 60
    private static let aboutRetryInterval: TimeInterval = 60

    private var browser: NWBrowser?
    private var browserGeneration = UUID()
    private var nameResolvers: [String: BonjourMacNameResolver] = [:]
    private var discoveredNames: [String: String] = [:]
    private var selectedEndpoint: NWEndpoint?
    private var selectedKey: Data?
    private var selectedPhoneID: UUID?
    private var activeSnapshotConnection: NWConnection?
    private var activeHistoryConnection: NWConnection?
    private var activeAboutConnection: NWConnection?
    private var pairer: PasscodePairer?
    private var timer: Timer?
    private var inFlight = false
    private var historyInFlight = false
    private var historyLoaded = false
    private var discoveryRequested = false
    private var discoveryPaused = false
    private var selectionGeneration = UUID()
    private var snapshotRequestID = UUID()
    private var sessionRequested = false {
        didSet {
            guard sessionRequested != oldValue else { return }
            UserDefaults.standard.set(sessionRequested, forKey: Self.resumeDashboardKey)
        }
    }
    private static let lastMacKey = "StatsForIOS.lastMac"
    private static let lastMacDisplayNameKey = "StatsForIOS.lastMacDisplayName"
    private static let manualHostKey = "StatsForIOS.manualHost"
    private static let manualPortKey = "StatsForIOS.manualPort"
    private static let refreshIntervalKey = "StatsForIOS.refreshIntervalSeconds"
    private static let resumeDashboardKey = "StatsForIOS.resumeDashboard"
    static let refreshIntervals = [2, 5, 10, 30]

    init() {
        let storedInterval = UserDefaults.standard.integer(forKey: Self.refreshIntervalKey)
        refreshIntervalSeconds = Self.refreshIntervals.contains(storedInterval) ? storedInterval : 2
        scheduleRefresh()
        restoreLastMac()
    }

    func setRefreshInterval(_ seconds: Int) {
        guard Self.refreshIntervals.contains(seconds), refreshIntervalSeconds != seconds else { return }
        refreshIntervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.refreshIntervalKey)
        scheduleRefresh()
        refresh()
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.startBrowserIfNeeded()
                self?.refresh()
            }
        }
    }

    private func restoreLastMac() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: Self.lastMacKey) else { return }
        guard let stored = PairingStore.load(for: name),
              let credential = PairingStore.decode(stored) else {
            PairingStore.delete(for: name)
            defaults.removeObject(forKey: Self.lastMacKey)
            defaults.removeObject(forKey: Self.lastMacDisplayNameKey)
            defaults.removeObject(forKey: Self.manualHostKey)
            defaults.removeObject(forKey: Self.manualPortKey)
            defaults.removeObject(forKey: Self.resumeDashboardKey)
            return
        }
        selectedName = name
        selectedDisplayName = defaults.string(forKey: Self.lastMacDisplayNameKey) ?? name
        selectedKey = credential.key
        selectedPhoneID = credential.phoneID
        restoreCachedAbout(for: credential.phoneID)
        sessionRequested = defaults.object(forKey: Self.resumeDashboardKey) as? Bool ?? true
        status = "Looking for \(selectedDisplayName ?? name)"
        if let host = defaults.string(forKey: Self.manualHostKey),
           let portNumber = defaults.object(forKey: Self.manualPortKey) as? Int,
           (1...65_535).contains(portNumber),
           let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) {
            selectedEndpoint = .hostPort(host: .init(host), port: port)
            refresh()
        }
        startDiscovery()
    }

    func startDiscovery() {
        discoveryRequested = true
        startBrowserIfNeeded()
    }

    func suspendForBackground() {
        discoveryPaused = true
        browserGeneration = UUID()
        browser?.cancel()
        browser = nil
        clearNameResolvers()
        devices = []
        selectedReachable = false
        selectionGeneration = UUID()
        cancelSnapshotRequest()
        cancelHistoryRequest()
        if activeAboutConnection != nil, aboutInfo == nil {
            aboutError = "Loading was interrupted. Try again."
        }
        cancelAboutRequest()
        historyLoaded = false
    }

    func resumeFromBackground() {
        discoveryPaused = false
        startBrowserIfNeeded()
        refresh()
    }

    private func clearNameResolvers() {
        for resolver in nameResolvers.values { resolver.stop() }
        nameResolvers.removeAll()
        discoveredNames.removeAll()
    }

    private func startBrowserIfNeeded() {
        guard discoveryRequested, !discoveryPaused, browser == nil else { return }
        let generation = UUID()
        browserGeneration = generation
        let browser = NWBrowser(for: .bonjour(type: SecurePacket.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browserGeneration == generation else { return }
                let availableNames = Set(results.compactMap { result -> String? in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return name
                })
                for name in self.nameResolvers.keys.filter({ !availableNames.contains($0) }) {
                    self.nameResolvers.removeValue(forKey: name)?.stop()
                    self.discoveredNames.removeValue(forKey: name)
                }
                self.devices = results.compactMap { result in
                    guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                    let advertisedName: String?
                    if case let .bonjour(record) = result.metadata {
                        advertisedName = record["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        advertisedName = nil
                    }
                    if let advertisedName, !advertisedName.isEmpty {
                        self.discoveredNames[name] = advertisedName
                    } else if self.nameResolvers[name] == nil {
                        let resolver = BonjourMacNameResolver(name: name, type: type, domain: domain) {
                            [weak self] resolvedName in
                            guard let self, self.browserGeneration == generation,
                                  self.devices.contains(where: { $0.name == name }),
                                  self.discoveredNames[name] != resolvedName else { return }
                            self.discoveredNames[name] = resolvedName
                            self.devices = self.devices.map { device in
                                guard device.name == name else { return device }
                                return Device(endpoint: device.endpoint, name: name, displayName: resolvedName)
                            }.sorted { $0.displayName < $1.displayName }
                            if self.selectedName == name { self.updateSelectedDisplayName(resolvedName) }
                        }
                        self.nameResolvers[name] = resolver
                        resolver.start()
                    }
                    return Device(endpoint: result.endpoint, name: name,
                                  displayName: self.discoveredNames[name])
                }.sorted { $0.displayName < $1.displayName }
                if let name = self.selectedName,
                   let device = self.devices.first(where: { $0.name == name }) {
                    self.selectedEndpoint = device.endpoint
                    if device.displayName != device.name {
                        self.updateSelectedDisplayName(device.displayName)
                    }
                    self.refresh()
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.browserGeneration == generation else { return }
                switch state {
                case .ready:
                    self.discoveryError = nil
                    if self.selectedName == nil { self.status = "Looking for Macs" }
                case .failed(let error):
                    self.discoveryError = error.localizedDescription
                    self.browserGeneration = UUID()
                    self.browser?.cancel()
                    self.browser = nil
                    self.clearNameResolvers()
                    self.devices = []
                    if self.selectedName == nil {
                        self.status = "Discovery failed: \(error.localizedDescription)"
                    } else if let selectedName = self.selectedName, self.selectedEndpoint == nil {
                        self.status = "Cannot connect · checking for \(self.selectedDisplayName ?? selectedName)"
                    }
                default: break
                }
            }
        }
        browser.start(queue: .main)
    }

    func pairWithPasscode(_ device: Device, code: String, phoneName: String,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        guard code.utf8.count == 5, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            completion(.failure(PasscodePairer.PairingError.invalidCode))
            return
        }
        let trimmedName = phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 60 else {
            completion(.failure(PasscodePairer.PairingError.invalidName))
            return
        }
        do {
            let pairer = try PasscodePairer(endpoint: device.endpoint, code: code,
                                           phoneName: trimmedName) {
                [weak self] result in
                guard let self else { return }
                self.pairer = nil
                switch result {
                case .success(let enrollment):
                    let previousPhoneID = PairingStore.load(for: device.name)
                        .flatMap { PairingStore.decode($0)?.phoneID }
                    let stored = PairingStore.encode(key: enrollment.credential, phoneID: enrollment.phoneID)
                    guard PairingStore.save(stored, for: device.name) else {
                        completion(.failure(PasscodePairer.PairingError.credentialSaveFailed))
                        return
                    }
                    if let previousPhoneID { self.removeCachedAbout(for: previousPhoneID) }
                    self.selectedName = device.name
                    self.selectedDisplayName = device.displayName
                    self.sessionRequested = true
                    self.sessionActive = false
                    self.selectedReachable = false
                    self.selectionGeneration = UUID()
                    self.cancelSnapshotRequest()
                    self.cancelHistoryRequest()
                    self.selectedEndpoint = device.endpoint
                    self.selectedKey = enrollment.credential
                    self.selectedPhoneID = enrollment.phoneID
                    self.aboutInfo = nil
                    self.aboutFetchedAt = nil
                    self.aboutLastAttemptAt = nil
                    self.aboutError = nil
                    self.cancelAboutRequest()
                    self.snapshot = nil
                    self.history = []
                    self.historyLoaded = false
                    self.status = "Connecting"
                    self.remember(device)
                    self.refresh()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            self.pairer = pairer
            pairer.start()
        } catch {
            completion(.failure(error))
        }
    }

    func pairManualWithPasscode(host: String, portString: String, code: String, phoneName: String,
                                completion: @escaping (Result<Void, Error>) -> Void) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let number = UInt16(portString),
              let port = NWEndpoint.Port(rawValue: number) else {
            completion(.failure(PasscodePairer.PairingError.connectionFailed))
            return
        }
        let device = Device(endpoint: .hostPort(host: .init(host), port: port), name: "\(host):\(number)")
        pairWithPasscode(device, code: code, phoneName: phoneName) { result in
            if case .success = result {
                UserDefaults.standard.set(host, forKey: Self.manualHostKey)
                UserDefaults.standard.set(Int(number), forKey: Self.manualPortKey)
            }
            completion(result)
        }
    }

    func select(_ device: Device) -> Bool {
        guard let stored = PairingStore.load(for: device.name),
              let credential = PairingStore.decode(stored) else { return false }
        let displayName = displayName(for: device)
        selectedName = device.name
        selectedDisplayName = displayName
        sessionRequested = true
        sessionActive = false
        selectedReachable = false
        selectionGeneration = UUID()
        cancelSnapshotRequest()
        cancelHistoryRequest()
        cancelAboutRequest()
        restoreCachedAbout(for: credential.phoneID)
        selectedEndpoint = device.endpoint
        selectedKey = credential.key
        selectedPhoneID = credential.phoneID
        snapshot = nil
        history = []
        historyLoaded = false
        status = "Connecting"
        remember(device)
        refresh()
        return true
    }

    func connectToSelectedMac() {
        guard selectedName != nil, selectedReachable else { return }
        sessionRequested = true
        sessionActive = true
        refresh()
    }

    func endSession() {
        sessionRequested = false
        sessionActive = false
    }

    func hasSavedPairing(_ device: Device) -> Bool {
        guard let stored = PairingStore.load(for: device.name) else { return false }
        return PairingStore.decode(stored) != nil
    }

    func displayName(for device: Device) -> String {
        if device.name == selectedName { return selectedDisplayName ?? device.displayName }
        return device.displayName
    }

    func forget() {
        if let selectedName { PairingStore.delete(for: selectedName) }
        if let selectedPhoneID { removeCachedAbout(for: selectedPhoneID) }
        selectedName = nil
        selectedDisplayName = nil
        sessionRequested = false
        sessionActive = false
        selectedReachable = false
        selectionGeneration = UUID()
        cancelSnapshotRequest()
        cancelHistoryRequest()
        cancelAboutRequest()
        aboutInfo = nil
        aboutFetchedAt = nil
        aboutLastAttemptAt = nil
        aboutError = nil
        selectedEndpoint = nil
        selectedKey = nil
        selectedPhoneID = nil
        snapshot = nil
        history = []
        historyLoaded = false
        status = "Looking for Macs"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastMacKey)
        defaults.removeObject(forKey: Self.lastMacDisplayNameKey)
        defaults.removeObject(forKey: Self.manualHostKey)
        defaults.removeObject(forKey: Self.manualPortKey)
        defaults.removeObject(forKey: Self.resumeDashboardKey)
    }

    private func remember(_ device: Device) {
        let defaults = UserDefaults.standard
        defaults.set(device.name, forKey: Self.lastMacKey)
        defaults.set(selectedDisplayName ?? device.displayName, forKey: Self.lastMacDisplayNameKey)
        if case let .hostPort(host, port) = device.endpoint {
            defaults.set(String(describing: host), forKey: Self.manualHostKey)
            defaults.set(Int(port.rawValue), forKey: Self.manualPortKey)
        } else {
            defaults.removeObject(forKey: Self.manualHostKey)
            defaults.removeObject(forKey: Self.manualPortKey)
        }
    }

    private func updateSelectedDisplayName(_ name: String) {
        guard !name.isEmpty, selectedDisplayName != name else { return }
        selectedDisplayName = name
        UserDefaults.standard.set(name, forKey: Self.lastMacDisplayNameKey)
    }

    private func refresh() {
        guard !discoveryPaused, !inFlight, let endpoint = selectedEndpoint, let key = selectedKey,
              let phoneID = selectedPhoneID else { return }
        inFlight = true
        let generation = selectionGeneration
        let requestID = UUID()
        snapshotRequestID = requestID
        let connection = NWConnection(to: endpoint, using: .tcp)
        activeSnapshotConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, on: connection, key: key, phoneID: phoneID,
                                              generation: generation, requestID: requestID) }
        }
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.selectionGeneration == generation,
                  self.snapshotRequestID == requestID, self.inFlight else { return }
            connection.cancel()
            self.fail()
        }
    }

    private func handle(_ state: NWConnection.State, on connection: NWConnection, key: Data,
                        phoneID: UUID, generation: UUID, requestID: UUID) {
            guard selectionGeneration == generation, snapshotRequestID == requestID, inFlight else {
                connection.cancel(); return
            }
            switch state {
            case .ready:
                guard let request = try? makeRequest("snapshot.v1", key: key, phoneID: phoneID) else {
                    fail(); return
                }
                connection.send(content: SecurePacket.frame(request), completion: .contentProcessed { error in
                    if error != nil {
                        connection.cancel()
                        Task { @MainActor in
                            if self.selectionGeneration == generation,
                               self.snapshotRequestID == requestID, self.inFlight { self.fail() }
                        }
                    }
                })
                receiveHeader(on: connection, key: key, generation: generation, requestID: requestID)
            case .failed:
                connection.cancel()
                fail()
            default: break
            }
    }

    private func makeRequest(_ command: String, key: Data, phoneID: UUID) throws -> Data {
        try PairingWire.authenticatedRequest(command, phoneID: phoneID, key: key)
    }

    private func receiveHeader(on connection: NWConnection, key: Data, generation: UUID, requestID: UUID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                guard self.selectionGeneration == generation,
                      self.snapshotRequestID == requestID, self.inFlight else { connection.cancel(); return }
                guard error == nil, let data, let length = SecurePacket.length(data) else {
                    connection.cancel(); self.fail(); return
                }
                self.receiveBody(on: connection, key: key, length: length,
                                 generation: generation, requestID: requestID)
            }
        }
    }

    private func receiveBody(on connection: NWConnection, key: Data, length: Int,
                             generation: UUID, requestID: UUID) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
            Task { @MainActor in
                defer { connection.cancel() }
                guard self?.selectionGeneration == generation,
                      self?.snapshotRequestID == requestID, self?.inFlight == true else { return }
                guard error == nil, let body,
                      let plaintext = try? SecurePacket.open(body, using: key),
                      let snapshot = try? JSONDecoder().decode(MetricSnapshot.self, from: plaintext),
                      snapshot.version == MetricSnapshot.protocolVersion else {
                    self?.fail(); return
                }
                self?.snapshot = snapshot
                self?.updateSelectedDisplayName(snapshot.machineName.trimmingCharacters(in: .whitespacesAndNewlines))
                self?.selectedReachable = true
                if self?.sessionRequested == true { self?.sessionActive = true }
                self?.append(snapshot)
                self?.status = "Last update \(snapshot.timestamp.formatted(date: .omitted, time: .standard))"
                self?.inFlight = false
                self?.activeSnapshotConnection = nil
                if self?.historyLoaded == false { self?.fetchHistory() }
                self?.loadAbout()
            }
        }
    }

    private func fail() {
        cancelSnapshotRequest()
        cancelHistoryRequest()
        historyLoaded = false
        selectedReachable = false
        sessionRequested = false
        sessionActive = false
        if let snapshot {
            status = "Disconnected · last update \(snapshot.timestamp.formatted(date: .omitted, time: .standard))"
        } else {
            status = "Cannot connect · check the Mac and pair again if needed"
        }
    }

    private func cancelSnapshotRequest() {
        snapshotRequestID = UUID()
        activeSnapshotConnection?.cancel()
        activeSnapshotConnection = nil
        inFlight = false
    }

    private func cancelHistoryRequest() {
        activeHistoryConnection?.cancel()
        activeHistoryConnection = nil
        historyInFlight = false
    }

    private func append(_ sample: MetricSnapshot) {
        guard sample.version == MetricSnapshot.protocolVersion else { return }
        if history.last?.timestamp != sample.timestamp { history.append(sample) }
        if history.count > 900 { history.removeFirst(history.count - 900) }
    }

    // Also called after the first authenticated snapshot, so the sheet has data before it opens.
    // Subsequent calls return immediately with the cached details and refresh them only when stale.
    func loadAbout(force: Bool = false) {
        guard activeAboutConnection == nil else { return }
        if !force, let aboutFetchedAt, aboutInfo != nil,
           Date().timeIntervalSince(aboutFetchedAt) < Self.aboutCacheLifetime { return }
        if !force, let aboutLastAttemptAt,
           Date().timeIntervalSince(aboutLastAttemptAt) < Self.aboutRetryInterval { return }
        guard let endpoint = selectedEndpoint, let key = selectedKey, let phoneID = selectedPhoneID,
              selectedReachable else {
            if aboutInfo == nil { aboutError = "This Mac is unavailable." }
            return
        }
        aboutError = nil
        aboutLastAttemptAt = .now
        let generation = selectionGeneration
        let connection = NWConnection(to: endpoint, using: .tcp)
        activeAboutConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.selectionGeneration == generation,
                      self.activeAboutConnection === connection else { connection.cancel(); return }
                switch state {
                case .ready:
                    guard let request = try? self.makeRequest("about.v1", key: key, phoneID: phoneID) else {
                        self.finishAbout(connection, error: "Couldn’t request Mac details.")
                        return
                    }
                    connection.send(content: SecurePacket.frame(request), completion: .contentProcessed { error in
                        if error != nil {
                            Task { @MainActor in
                                self.finishAbout(connection, error: "Couldn’t reach this Mac.")
                            }
                        }
                    })
                    self.receiveAboutHeader(on: connection, key: key, phoneID: phoneID, generation: generation)
                case .failed:
                    self.finishAbout(connection, error: "Couldn’t reach this Mac.")
                default: break
                }
            }
        }
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.finishAbout(connection, error: "Mac details timed out. Try again.")
        }
    }

    private func receiveAboutHeader(on connection: NWConnection, key: Data,
                                    phoneID: UUID, generation: UUID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.selectionGeneration == generation,
                      self.activeAboutConnection === connection else { connection.cancel(); return }
                guard error == nil, let data, let length = SecurePacket.length(data) else {
                    self.finishAbout(connection, error: "Couldn’t read Mac details.")
                    return
                }
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                    Task { @MainActor in
                        guard let self, self.selectionGeneration == generation,
                              self.activeAboutConnection === connection else { connection.cancel(); return }
                        guard error == nil, let body,
                              let plaintext = try? SecurePacket.open(body, using: key),
                              let info = try? JSONDecoder().decode(MacAboutInfo.self, from: plaintext) else {
                            self.finishAbout(connection, error: "Couldn’t read Mac details.")
                            return
                        }
                        self.aboutInfo = info
                        self.aboutFetchedAt = .now
                        self.storeCachedAbout(info, for: phoneID)
                        self.finishAbout(connection, error: nil)
                    }
                }
            }
        }
    }

    private func finishAbout(_ connection: NWConnection, error: String?) {
        guard activeAboutConnection === connection else { return }
        if let error, aboutInfo == nil { aboutError = error }
        cancelAboutRequest()
    }

    private func cancelAboutRequest() {
        activeAboutConnection?.cancel()
        activeAboutConnection = nil
    }

    // Cache only within the app's private, non-backed-up Caches directory. A fresh pairing
    // receives a different phone ID, so it cannot display another pairing's cached details.
    private func aboutCacheURL(for phoneID: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacAbout", isDirectory: true)
            .appendingPathComponent(phoneID.uuidString + ".json")
    }

    private func restoreCachedAbout(for phoneID: UUID) {
        aboutInfo = nil
        aboutFetchedAt = nil
        aboutLastAttemptAt = nil
        aboutError = nil
        guard let data = try? Data(contentsOf: aboutCacheURL(for: phoneID)),
              let cached = try? JSONDecoder().decode(CachedMacAbout.self, from: data) else { return }
        aboutInfo = cached.info
        aboutFetchedAt = cached.fetchedAt
    }

    private func storeCachedAbout(_ info: MacAboutInfo, for phoneID: UUID) {
        let url = aboutCacheURL(for: phoneID)
        let cached = CachedMacAbout(fetchedAt: .now, info: info)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func removeCachedAbout(for phoneID: UUID) {
        try? FileManager.default.removeItem(at: aboutCacheURL(for: phoneID))
    }

    private func fetchHistory() {
        guard !historyInFlight, let endpoint = selectedEndpoint, let key = selectedKey,
              let phoneID = selectedPhoneID else { return }
        historyInFlight = true
        let generation = selectionGeneration
        let connection = NWConnection(to: endpoint, using: .tcp)
        activeHistoryConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                guard self.selectionGeneration == generation else { connection.cancel(); return }
                switch state {
                case .ready:
                    guard let request = try? self.makeRequest("history.v1", key: key, phoneID: phoneID) else {
                        self.cancelHistoryRequest(); return
                    }
                    connection.send(content: SecurePacket.frame(request), completion: .contentProcessed { error in
                        if error != nil {
                            Task { @MainActor in
                                if self.selectionGeneration == generation,
                                   self.activeHistoryConnection === connection { self.cancelHistoryRequest() }
                            }
                        }
                    })
                    self.receiveHistoryHeader(on: connection, key: key, generation: generation)
                case .failed:
                    self.cancelHistoryRequest()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.selectionGeneration == generation,
                  self.activeHistoryConnection === connection else { return }
            self.cancelHistoryRequest()
        }
    }

    private func receiveHistoryHeader(on connection: NWConnection, key: Data, generation: UUID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard self?.selectionGeneration == generation,
                      self?.activeHistoryConnection === connection else { connection.cancel(); return }
                guard error == nil, let data, let length = SecurePacket.length(data) else {
                    self?.cancelHistoryRequest(); return
                }
                self?.receiveHistoryBody(on: connection, key: key, length: length, generation: generation)
            }
        }
    }

    private func receiveHistoryBody(on connection: NWConnection, key: Data, length: Int, generation: UUID) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                guard self.selectionGeneration == generation,
                      self.activeHistoryConnection === connection else { connection.cancel(); return }
                defer { self.cancelHistoryRequest() }
                guard error == nil, let body,
                      let plaintext = try? SecurePacket.open(body, using: key),
                      let samples = try? JSONDecoder().decode([MetricSnapshot].self, from: plaintext) else { return }
                self.mergeHistory(samples)
                self.historyLoaded = true
            }
        }
    }

    private func mergeHistory(_ samples: [MetricSnapshot]) {
        let valid = (history + samples).filter {
            $0.version == MetricSnapshot.protocolVersion && $0.timestamp > Date().addingTimeInterval(-31 * 60)
        }
        history = Array(Dictionary(valid.map { ($0.timestamp, $0) }, uniquingKeysWith: { latest, _ in latest })
            .values.sorted { $0.timestamp < $1.timestamp }.suffix(900))
    }
}

private enum PairingStore {
    static func encode(key: Data, phoneID: UUID) -> Data {
        PairingWire.requestPrefix + Data(phoneID.uuidString.utf8) + key
    }

    static func decode(_ stored: Data) -> (key: Data, phoneID: UUID)? {
        let prefix = PairingWire.requestPrefix
        guard stored.count == prefix.count + 36 + 32, stored.starts(with: prefix),
              let idString = String(data: stored[prefix.count..<(prefix.count + 36)], encoding: .utf8),
              let id = UUID(uuidString: idString) else { return nil }
        return (Data(stored.suffix(32)), id)
    }
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.ishtiaqsyed.StatsForIOS.pairing",
         kSecAttrAccount as String: name]
    }

    @discardableResult
    static func save(_ key: Data, for name: String) -> Bool {
        let base = query(name)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var values = base
        values[kSecValueData as String] = key
        return SecItemAdd(values as CFDictionary, nil) == errSecSuccess
    }

    static func load(for name: String) -> Data? {
        var values = query(name)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(for name: String) { SecItemDelete(query(name) as CFDictionary) }
}
