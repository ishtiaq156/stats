import CryptoKit
import Foundation

@main
struct UpdateInstallerTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsInstallerDigestTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let contents = Data("Verified Stats Companion update".utf8)
        let file = directory.appendingPathComponent("package.dmg")
        try contents.write(to: file)
        let expected = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()

        try CompanionUpdateInstaller.verifyDigest(file, expected: expected)

        try Data("Tampered Stats Companion update".utf8).write(to: file)
        do {
            try CompanionUpdateInstaller.verifyDigest(file, expected: expected)
            fatalError("A modified package must fail digest verification.")
        } catch {
            precondition(error.localizedDescription.contains("checksum"))
        }
        print("Update installer: authentic package accepted; tampered package rejected")
    }
}
