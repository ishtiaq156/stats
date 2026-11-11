import ActivityCore
import Foundation
import Network

@MainActor
private final class Runner {
    private let service = "com.ishtiaqsyed.StatsCompanion.smoke.\(UUID())"
    private var server: MetricServer!
    private var pairer: PasscodePairer?
    private var fetch: NWConnection?
    private var code: String?
    private var port: UInt16?
    private var result: String?
    private var revokedEnrollment: PairingWire.Enrollment?

    init() {
        server = MetricServer(
            snapshot: { MetricSnapshot(machineName: "Pairing smoke Mac") },
            history: { [] },
            about: {
                MacAboutInfo(modelName: "Pairing smoke Mac", chip: nil, memory: nil,
                             startupDisk: nil, serialNumber: nil, macOS: "Smoke", imagePNG: nil)
            },
            onPort: { [weak self] port in self?.port = port; self?.startPairingIfReady() },
            onDiscovery: { _, _ in },
            onPhones: { [weak self] phones in
                guard let self, let enrollment = self.revokedEnrollment,
                      !phones.contains(where: { $0.id == enrollment.phoneID }) else { return }
                self.revokedEnrollment = nil
                self.checkRevoked(enrollment)
            },
            onPairingEnded: { _ in },
            phones: PhoneRegistry(service: service)
        )
    }

    func run() {
        server.start()
        server.beginPairing { [weak self] oldCode, _ in
            self?.server.beginPairing { [weak self] freshCode, _ in
                guard let self else { return }
                guard freshCode != oldCode else {
                    self.result = "Refreshing did not rotate the pairing code"
                    return
                }
                self.code = freshCode
                self.startPairingIfReady()
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while result == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        server.stop()
        guard result == "pass" else { fatalError(result ?? "Pairing smoke test timed out") }
        print("Pairing smoke test passed")
    }

    private func startPairingIfReady() {
        guard pairer == nil, let code, let port else { return }
        do {
            pairer = try PasscodePairer(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                        code: code, phoneName: "Smoke iPhone") { [weak self] result in
                guard let self else { return }
                self.pairer = nil
                switch result {
                case .success(let enrollment): self.fetchSnapshot(enrollment)
                case .failure(let error): self.result = "Pairing failed: \(error)"
                }
            }
            pairer?.start()
        } catch {
            result = "Could not start pairing: \(error)"
        }
    }

    private func fetchSnapshot(_ enrollment: PairingWire.Enrollment) {
        guard let port else { result = "Missing port"; return }
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), using: .tcp)
        fetch = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.sendAuthenticatedSnapshot(connection, enrollment: enrollment)
                case .failed(let error): self.result = "Connection failed: \(error)"
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func sendAuthenticatedSnapshot(_ connection: NWConnection, enrollment: PairingWire.Enrollment) {
        do {
            let request = try PairingWire.authenticatedRequest("snapshot.v1", phoneID: enrollment.phoneID,
                                                                key: enrollment.credential)
            connection.send(content: SecurePacket.frame(request), completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error { self.result = "Send failed: \(error)"; return }
                    self.receiveSnapshotHeader(connection, enrollment: enrollment)
                }
            })
        } catch {
            result = "Could not make request: \(error)"
        }
    }

    private func receiveSnapshotHeader(_ connection: NWConnection, enrollment: PairingWire.Enrollment) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let header, let length = SecurePacket.length(header) else {
                    self.result = "Missing response header"
                    return
                }
                self.receiveSnapshotBody(connection, length: length, enrollment: enrollment)
            }
        }
    }

    private func receiveSnapshotBody(_ connection: NWConnection, length: Int,
                                     enrollment: PairingWire.Enrollment) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let body,
                      let opened = try? SecurePacket.open(body, using: enrollment.credential),
                      let snapshot = try? JSONDecoder().decode(MetricSnapshot.self, from: opened),
                      snapshot.machineName == "Pairing smoke Mac" else {
                    self.result = "Invalid authenticated snapshot"
                    return
                }
                let restored = PhoneRegistry(service: self.service)
                guard restored.key(for: enrollment.phoneID) == enrollment.credential,
                      restored.all().first?.name == "Smoke iPhone" else {
                    self.result = "Credential was not restored from Keychain"
                    return
                }
                self.revokedEnrollment = enrollment
                self.server.revokePhone(enrollment.phoneID)
                connection.cancel()
            }
        }
    }

    private func checkRevoked(_ enrollment: PairingWire.Enrollment) {
        guard let port else { result = "Missing port"; return }
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), using: .tcp)
        fetch = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.sendRevokedRequest(connection, enrollment: enrollment)
                case .failed(let error): self.result = "Revocation connection failed: \(error)"
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func sendRevokedRequest(_ connection: NWConnection, enrollment: PairingWire.Enrollment) {
        guard let request = try? PairingWire.authenticatedRequest(
            "snapshot.v1", phoneID: enrollment.phoneID, key: enrollment.credential
        ) else { result = "Could not make revoked request"; return }
        connection.send(content: SecurePacket.frame(request), completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard error == nil else { self.result = "Revoked request could not be sent"; return }
                connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, complete, error in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.result = header == nil && complete && error == nil
                            ? "pass" : "Revoked phone received a response"
                        connection.cancel()
                    }
                }
            }
        })
    }
}

@main
struct PairingSmoke {
    @MainActor
    static func main() {
        let runner = Runner()
        runner.run()
    }
}
