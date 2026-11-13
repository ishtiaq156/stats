import Foundation

@main
struct UpdateReleaseTests {
    private static func release(
        _ version: String,
        draft: Bool = false,
        asset: String? = nil,
        url: String? = nil,
        assetURL: String? = nil,
        digest: String? = "sha256:" + String(repeating: "a", count: 64)
    ) -> [String: Any] {
        let asset = asset ?? "StatsCompanion-\(version)-macOS-universal.dmg"
        return [
            "tag_name": version,
            "html_url": url ?? "https://github.com/ishtiaq156/stats/releases/tag/\(version)",
            "draft": draft,
            "prerelease": true,
            "assets": asset.isEmpty ? [] : [[
                "name": asset,
                "browser_download_url": assetURL ?? "https://github.com/ishtiaq156/stats/releases/download/\(version)/\(asset)",
                "digest": digest as Any
            ]]
        ]
    }

    private static func selected(_ releases: [[String: Any]], from version: String = "0.3.2") throws -> CompanionAvailableRelease? {
        let data = try JSONSerialization.data(withJSONObject: releases)
        return try CompanionUpdateRelease.newest(in: data, newerThan: version)
    }

    private static func expect(_ releases: [[String: Any]], from current: String = "0.3.2", version expected: String?) throws {
        let actual = try selected(releases, from: current)?.version
        precondition(actual == expected, "Expected \(expected ?? "none"), got \(actual ?? "none")")
    }

    static func main() throws {
        try expect([], version: nil)
        try expect([release("v0.3.2"), release("v0.3.1")], version: nil)
        try expect([release("v0.3.3")], version: "0.3.3")
        let combinedRelease = release(
            "v0.3.14",
            asset: "StatsCompanion-v0.3.10-macOS-universal.zip"
        )
        try expect([combinedRelease], from: "0.3.9", version: "0.3.10")
        let combinedMatch = try selected([combinedRelease], from: "0.3.9")
        precondition(combinedMatch?.downloadURL.path ==
                     "/ishtiaq156/stats/releases/download/v0.3.14/StatsCompanion-v0.3.10-macOS-universal.zip")
        try expect([combinedRelease], from: "0.3.10", version: nil)
        try expect([release("v0.4.0", asset: "StatsCompanion-v0.4.0-macOS-universal.dmg"),
                    release("v0.9.0", asset: "StatsCompanion-v0.9.0-macOS-universal.dmg"),
                    release("v0.10.0", asset: "StatsCompanion-v0.10.0-macOS-universal.dmg")], version: "0.10.0")
        try expect([release("v0.4.0", draft: true), release("v0.3.3")], version: "0.3.3")
        try expect([release("v0.4.0", asset: "")], version: nil)
        try expect([release("v0.4.0", asset: "Stats-iPhone.ipa")], version: nil)
        try expect([release("v0.4.0", asset: "StatsCompanion-v0.4.0-macOS-universal.zip")], version: "0.4.0")
        var both = release("v0.4.0", asset: "StatsCompanion-v0.4.0-macOS-universal.dmg")
        both["assets"] = [
            ["name": "StatsCompanion-v0.4.0-macOS-universal.dmg",
             "browser_download_url": "https://github.com/ishtiaq156/stats/releases/download/v0.4.0/StatsCompanion-v0.4.0-macOS-universal.dmg",
             "digest": "sha256:" + String(repeating: "a", count: 64)],
            ["name": "StatsCompanion-v0.4.0-macOS-universal.zip",
             "browser_download_url": "https://github.com/ishtiaq156/stats/releases/download/v0.4.0/StatsCompanion-v0.4.0-macOS-universal.zip",
             "digest": "sha256:" + String(repeating: "b", count: 64)]
        ]
        let preferred = try selected([both])
        precondition(preferred?.assetName.hasSuffix(".zip") == true,
                     "The in-app updater must prefer ZIP when a release includes both formats")
        try expect([release("v0.4.0-beta.1"), release("not-a-version")], version: nil)
        try expect([release("v0.4.0", url: "https://untrusted.example/releases/tag/v0.4.0")], version: nil)
        try expect([release("v0.4.0", asset: "StatsCompanion-v0.4.0-macOS-universal.dmg",
                           assetURL: "https://example.com/update.dmg")], version: nil)
        try expect([release("v0.4.0", asset: "StatsCompanion-v0.4.0-macOS-universal.dmg",
                           digest: "sha256:bad")], version: nil)
        try expect([release("v0.3.3")], from: "invalid", version: nil)

        do {
            _ = try CompanionUpdateRelease.newest(in: Data("bad json".utf8), newerThan: "0.3.2")
            fatalError("Malformed release JSON should throw")
        } catch is DecodingError {
            // Expected.
        }

        print("Update availability and trusted asset selection passed")
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            for installedVersion in ["0.3.1", "0.3.2", "0.3.9"] {
                let match = try CompanionUpdateRelease.newest(in: data, newerThan: installedVersion)
                print("Live GitHub response for \(installedVersion): \(match?.version ?? "no update")")
            }
        }
    }
}
