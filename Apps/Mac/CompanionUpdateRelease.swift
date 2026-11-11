import Foundation

struct CompanionAvailableRelease: Equatable {
    let version: String
    let url: URL
}

/// Selects a newer downloadable Mac release from GitHub's releases list.
/// Unlike /releases/latest, the list includes pre-releases.
enum CompanionUpdateRelease {
    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let assets: [Asset]

        struct Asset: Decodable { let name: String }
    }

    static func newest(in data: Data, newerThan current: String) throws -> CompanionAvailableRelease? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let currentParts = versionParts(current) else { return nil }
        return releases.compactMap { release -> (parts: [Int], result: CompanionAvailableRelease)? in
            guard !release.draft,
                  release.html_url.scheme == "https",
                  release.html_url.host == "github.com",
                  release.html_url.path.hasPrefix("/ishtiaq156/stats/releases/tag/"),
                  release.assets.contains(where: {
                      $0.name.hasPrefix("StatsCompanion-") &&
                      ($0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".zip"))
                  }),
                  let parts = versionParts(release.tag_name),
                  currentParts.lexicographicallyPrecedes(parts) else { return nil }

            let version = release.tag_name.first == "v" || release.tag_name.first == "V"
                ? String(release.tag_name.dropFirst()) : release.tag_name
            return (parts, CompanionAvailableRelease(version: version, url: release.html_url))
        }.max { $0.parts.lexicographicallyPrecedes($1.parts) }?.result
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
