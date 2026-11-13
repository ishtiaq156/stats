import Foundation

struct CompanionAvailableRelease: Equatable, Sendable {
    let version: String
    let url: URL
    let downloadURL: URL
    let assetName: String
    let sha256: String
}

/// Selects a newer downloadable Mac release from GitHub's releases list.
/// Unlike /releases/latest, the list includes pre-releases.
enum CompanionUpdateRelease {
    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL?
            let digest: String?
        }
    }

    static func newest(in data: Data, newerThan current: String) throws -> CompanionAvailableRelease? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let currentParts = versionParts(current) else { return nil }
        return releases.flatMap { release -> [(parts: [Int], result: CompanionAvailableRelease)] in
            guard !release.draft,
                  release.html_url.scheme == "https",
                  release.html_url.host == "github.com",
                  release.tag_name.first == "v",
                  versionParts(release.tag_name) != nil,
                  release.html_url.path == "/ishtiaq156/stats/releases/tag/\(release.tag_name)"
            else { return [] }

            return release.assets.compactMap { asset -> (parts: [Int], result: CompanionAvailableRelease)? in
                let prefix = "StatsCompanion-v"
                let suffix = "-macOS-universal"
                guard asset.name.hasPrefix(prefix) else { return nil }
                let extensionName: String
                if asset.name.hasSuffix(".zip") { extensionName = ".zip" }
                else if asset.name.hasSuffix(".dmg") { extensionName = ".dmg" }
                else { return nil }
                let stem = String(asset.name.dropLast(extensionName.count))
                guard stem.hasSuffix(suffix) else { return nil }
                let version = String(stem.dropFirst(prefix.count).dropLast(suffix.count))
                guard let parts = versionParts(version),
                      currentParts.lexicographicallyPrecedes(parts),
                      let downloadURL = asset.browser_download_url,
                      downloadURL.scheme == "https", downloadURL.host == "github.com",
                      downloadURL.path == "/ishtiaq156/stats/releases/download/\(release.tag_name)/\(asset.name)",
                      let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
                let sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
                guard sha256.utf8.count == 64,
                      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
                return (parts, CompanionAvailableRelease(
                    version: version, url: release.html_url, downloadURL: downloadURL,
                    assetName: asset.name, sha256: sha256
                ))
            }
        }.max {
            if $0.parts != $1.parts { return $0.parts.lexicographicallyPrecedes($1.parts) }
            // Prefer a valid ZIP over a DMG for the same Mac version.
            return $0.result.assetName.hasSuffix(".dmg") && $1.result.assetName.hasSuffix(".zip")
        }?.result
    }

    private static func versionParts(_ raw: String) -> [Int]? {
        let stripped = raw.first == "v" || raw.first == "V" ? raw.dropFirst() : Substring(raw)
        let components = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ 48...57 ~= $0 }) }) else {
            return nil
        }
        let numbers = components.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
}
