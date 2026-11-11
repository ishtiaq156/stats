import Foundation

public enum PairingWire {
    public static let helloPrefix = Data("PAIR2".utf8)
    public static let requestPrefix = Data("AUTH2".utf8)
    public static let confirmation = Data("confirm.v2".utf8)

    public struct Hello: Codable {
        public let message: Data

        public init(message: Data) {
            self.message = message
        }
    }

    public struct Enrollment: Codable, Sendable {
        public let phoneID: UUID
        public let credential: Data

        public init(phoneID: UUID, credential: Data) {
            self.phoneID = phoneID
            self.credential = credential
        }
    }

    public struct Claim: Codable {
        public let phoneName: String

        public init(phoneName: String) {
            self.phoneName = phoneName
        }
    }

    public static func authenticatedRequest(_ command: String, phoneID: UUID, key: Data) throws -> Data {
        let encrypted = try SecurePacket.seal(Data(command.utf8), using: key)
        return requestPrefix + Data(phoneID.uuidString.utf8) + encrypted
    }
}
