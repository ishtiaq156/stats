import CryptoKit
import Darwin
import Foundation
import Security

enum CompanionInstallationState: Equatable {
    case idle
    case downloading(Double?)
    case ready
    case installing
    case failed(String)
}

struct PreparedCompanionUpdate: Sendable {
    let release: CompanionAvailableRelease
    let directory: URL
    let packageURL: URL
    let appURL: URL
}

private struct CompanionUpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class CompanionDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @MainActor @Sendable (Double?) -> Void

    init(report: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        Task { @MainActor in report(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

/// The UI keeps the downloaded installer after a permission error so it can be
/// opened manually. All app replacements are staged and signature-checked
/// before the running process exits.
enum CompanionUpdateInstaller {
    static func prepare(
        _ release: CompanionAvailableRelease,
        reportProgress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> PreparedCompanionUpdate {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("StatsCompanionUpdate-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let package = directory.appendingPathComponent(release.assetName)
        do {
            var request = URLRequest(url: release.downloadURL)
            request.setValue("StatsCompanion", forHTTPHeaderField: "User-Agent")
            let delegate = CompanionDownloadProgress(report: reportProgress)
            let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw CompanionUpdateError(message: "The update download failed.")
            }
            try Task.checkCancellation()
            try manager.moveItem(at: temporary, to: package)
            let stagedApp = directory.appendingPathComponent("StatsCompanion.app", isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                try verifyDigest(package, expected: release.sha256)
                try unpack(package, into: stagedApp, in: directory)
                try verifyApp(stagedApp, version: release.version)
            }.value
            try Task.checkCancellation()
            return PreparedCompanionUpdate(release: release, directory: directory,
                                           packageURL: package, appURL: stagedApp)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    static func installAndRelaunch(_ update: PreparedCompanionUpdate) async throws {
        let current = Bundle.main.bundleURL.standardizedFileURL
        guard current.isFileURL, current.pathExtension == "app",
              current.lastPathComponent == "StatsCompanion.app",
              FileManager.default.fileExists(atPath: current.path),
              !isSymbolicLink(current) else {
            throw CompanionUpdateError(message: "Open the downloaded installer to update this copy of Stats Companion.")
        }
        let parent = current.deletingLastPathComponent()
        let replacement = parent.appendingPathComponent(".StatsCompanion-update-\(UUID().uuidString).app")
        let backup = parent.appendingPathComponent(".StatsCompanion-backup-\(UUID().uuidString).app")

        do {
            try await Task.detached(priority: .userInitiated) {
                try verifyApp(update.appURL, version: update.release.version)
                try run("/usr/bin/ditto", [update.appURL.path, replacement.path])
                try verifyApp(replacement, version: update.release.version)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw CompanionUpdateError(message: "Cannot prepare the update in Applications. Open the downloaded installer to install manually.")
        }

        do {
            try startHelper(script: swapScript, arguments: [
                current.path, replacement.path, backup.path,
                String(ProcessInfo.processInfo.processIdentifier), update.directory.path
            ])
        } catch {
            try? FileManager.default.removeItem(at: replacement)
            throw CompanionUpdateError(message: "Could not start the updater. Try again or open the downloaded installer.")
        }
    }

    static func restart() throws {
        let current = Bundle.main.bundleURL.standardizedFileURL
        guard current.pathExtension == "app" else {
            throw CompanionUpdateError(message: "Could not find Stats Companion to restart.")
        }
        try startHelper(script: restartScript, arguments: [
            current.path, String(ProcessInfo.processInfo.processIdentifier)
        ])
    }

    static func discard(_ update: PreparedCompanionUpdate) {
        try? FileManager.default.removeItem(at: update.directory)
    }

    static func verifyDigest(_ file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += chunk.count
            guard count <= 250 * 1024 * 1024 else {
                throw CompanionUpdateError(message: "Update package exceeds the allowed size.")
            }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw CompanionUpdateError(message: "Update checksum did not match the published release.")
        }
    }

    private static func unpack(_ package: URL, into destination: URL, in directory: URL) throws {
        let manager = FileManager.default
        let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
        try manager.createDirectory(at: extracted, withIntermediateDirectories: false)
        if package.pathExtension == "dmg" {
            // macOS 27 requires diskutil's image API here; hdiutil attach
            // reports Permission denied even for a valid signed release.
            try run("/usr/sbin/diskutil", [
                "image", "attach", "--readOnly", "--nobrowse",
                "--mountPoint", extracted.path, package.path
            ])
            defer { try? run("/usr/sbin/diskutil", ["eject", extracted.path]) }
            let source = extracted.appendingPathComponent("StatsCompanion.app", isDirectory: true)
            guard manager.fileExists(atPath: source.path), !isSymbolicLink(source) else {
                throw CompanionUpdateError(message: "The downloaded installer contains no valid Mac app.")
            }
            try run("/usr/bin/ditto", [source.path, destination.path])
        } else if package.pathExtension == "zip" {
            try run("/usr/bin/ditto", ["-x", "-k", package.path, extracted.path])
            let source = extracted.appendingPathComponent("StatsCompanion.app", isDirectory: true)
            guard manager.fileExists(atPath: source.path), !isSymbolicLink(source) else {
                throw CompanionUpdateError(message: "The downloaded archive contains no valid Mac app.")
            }
            try run("/usr/bin/ditto", [source.path, destination.path])
        } else {
            throw CompanionUpdateError(message: "Unsupported update package.")
        }
        try? manager.removeItem(at: extracted)
    }

    private static func verifyApp(_ app: URL, version: String) throws {
        guard !isSymbolicLink(app),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "com.ishtiaqsyed.StatsCompanion",
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            throw CompanionUpdateError(message: "The update does not match Stats Companion or its version.")
        }
        var current: SecCode?
        var currentStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess,
              let currentStatic,
              SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
              let candidate,
              SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess,
              let currentTeam = signingTeam(currentStatic), !currentTeam.isEmpty,
              signingTeam(candidate) == currentTeam else {
            throw CompanionUpdateError(message: "The update's code signature could not be verified against this app.")
        }
    }

    private static func signingTeam(_ code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Disk-image services can hang after a macOS permission change.
        // Bound staging work so the menu can offer retry on failure.
        if finished.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw CompanionUpdateError(message: "Preparing the installer timed out. Please try again.")
        }
        guard process.terminationStatus == 0 else {
            throw CompanionUpdateError(message: "Unable to prepare update (exit \(process.terminationStatus)).")
        }
    }

    private static func startHelper(script: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "stats-companion-updater"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // Paths are positional argv, never interpolated into shell code. Staging
    // and backup are siblings of the installed app, so moves are atomic.
    private static let swapScript = """
        old="$1"
        replacement="$2"
        backup="$3"
        pid="$4"
        work="$5"
        tries=0
        while /bin/kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 300 ]; do
            /bin/sleep 0.2
            tries=$((tries + 1))
        done
        if /bin/kill -0 "$pid" 2>/dev/null; then exit 1; fi
        if /bin/mv "$old" "$backup"; then
            if /bin/mv "$replacement" "$old"; then
                if /usr/bin/open -a "$old"; then
                    /bin/rm -rf "$backup" "$work"
                    exit 0
                fi
                /bin/mv "$old" "$replacement"
            fi
            /bin/mv "$backup" "$old"
            /usr/bin/open -a "$old"
        else
            /usr/bin/open -a "$old"
        fi
        exit 1
        """

    private static let restartScript = """
        app="$1"
        pid="$2"
        tries=0
        while /bin/kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 300 ]; do
            /bin/sleep 0.2
            tries=$((tries + 1))
        done
        if /bin/kill -0 "$pid" 2>/dev/null; then exit 1; fi
        /usr/bin/open -a "$app"
        """
}
