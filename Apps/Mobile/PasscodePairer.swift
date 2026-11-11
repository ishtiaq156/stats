import ActivityCore
import Foundation
import Network

@MainActor
final class PasscodePairer {
    enum PairingError: LocalizedError {
        case invalidResponse, timedOut, connectionFailed, credentialSaveFailed, invalidName, invalidCode

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The passcode was rejected or the pairing session ended."
            case .timedOut: return "Pairing timed out. Start a new passcode on the Mac."
            case .connectionFailed: return "Could not reach the Mac. Check its address and port."
            case .credentialSaveFailed: return "Pairing succeeded, but this iPhone could not save its credential. Pair again with a new code."
            case .invalidName: return "Use a phone name between 1 and 60 characters."
            case .invalidCode: return "Enter the five-digit passcode shown on the Mac."
            }
        }
    }

    private let connection: NWConnection
    private let exchange: PairingExchange
    private let phoneName: String
    private var completion: (@MainActor (Result<PairingWire.Enrollment, Error>) -> Void)?
    private var finished = false

    init(endpoint: NWEndpoint, code: String, phoneName: String,
         completion: @escaping @MainActor (Result<PairingWire.Enrollment, Error>) -> Void) throws {
        exchange = try PairingExchange(role: .phone, code: code)
        connection = NWConnection(to: endpoint, using: .tcp)
        self.phoneName = phoneName
        self.completion = completion
    }

    func start() {
        // NWConnection delivers state, send, and receive callbacks on this queue.
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.sendHello()
                case .failed: self.finish(.failure(PairingError.connectionFailed))
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(.failure(PairingError.timedOut))
        }
    }

    private func sendHello() {
        guard let encoded = try? JSONEncoder().encode(
            PairingWire.Hello(message: exchange.message)
        ) else {
            finish(.failure(PairingError.invalidResponse))
            return
        }
        send(PairingWire.helloPrefix + encoded) { [weak self] in
            self?.receiveFrame { [weak self] body in
                self?.handleChallenge(body)
            }
        }
    }

    private func handleChallenge(_ body: Data?) {
        guard let body, body.starts(with: PairingWire.helloPrefix),
              body.count == PairingWire.helloPrefix.count + 33,
              let key = try? exchange.finish(peerMessage: Data(body.dropFirst(PairingWire.helloPrefix.count))),
              let claim = try? JSONEncoder().encode(PairingWire.Claim(phoneName: phoneName)),
              let confirmation = try? SecurePacket.seal(claim, using: key) else {
            finish(.failure(PairingError.invalidResponse))
            return
        }
        send(confirmation) { [weak self] in
            self?.receiveFrame { [weak self] body in
                guard let self, let body,
                      let opened = try? SecurePacket.open(body, using: key),
                      let enrollment = try? JSONDecoder().decode(PairingWire.Enrollment.self, from: opened),
                      enrollment.credential.count == 32 else {
                    self?.finish(.failure(PairingError.invalidResponse))
                    return
                }
                self.finish(.success(enrollment))
            }
        }
    }

    private func send(_ body: Data, then: @escaping @MainActor () -> Void) {
        connection.send(content: SecurePacket.frame(body), completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if error != nil { self?.finish(.failure(PairingError.connectionFailed)) }
                else { then() }
            }
        })
    }

    private func receiveFrame(_ completion: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil, let header, let length = SecurePacket.length(header) else {
                    completion(nil)
                    return
                }
                self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                    MainActor.assumeIsolated { completion(error == nil ? body : nil) }
                }
            }
        }
    }

    private func finish(_ result: Result<PairingWire.Enrollment, Error>) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        let callback = completion
        completion = nil
        callback?(result)
    }
}
