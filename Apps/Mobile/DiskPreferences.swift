import ActivityCore
import Foundation

enum DiskDisplayPreference {
    static let selectedDiskKey = "Stats.selectedDiskID"
    static let showSpeedKey = "Stats.showDiskSpeedWidget"
    static let showTextKey = "Stats.showDiskTextWidget"
    static let processCountKey = "Stats.diskProcessCount"
    static let speedBaseKey = "Stats.diskSpeedBase"
    static let speedUnitKey = "Stats.diskSpeedUnit"
    static let textTemplateKey = "Stats.diskTextTemplate"
    static let readColorKey = "Stats.diskReadColor"
    static let writeColorKey = "Stats.diskWriteColor"
    static let reverseChartOrderKey = "Stats.diskReverseChartOrder"
    static let hiddenCardsKey = "Stats.diskHiddenCards"
    static let collapsedCardsKey = "Stats.diskCollapsedCards"

    static func cardIDs(in data: Data) -> Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    static func cardIDs(_ ids: Set<String>) -> Data {
        (try? JSONEncoder().encode(ids)) ?? Data()
    }

    static func selectedVolume(in snapshot: MetricSnapshot, id: String,
                               showRemovable: Bool = false) -> DiskVolume? {
        let volumes = (snapshot.diskDetails?.volumes ?? []).filter {
            showRemovable || $0.isRemovable != true
        }
        return volumes.first(where: { $0.id == id }) ?? volumes.first(where: { $0.mountPath == "/" })
    }

    static func rate(_ value: Double?, base: String, unit: String) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let scaled = value * (base == "bit" ? 8 : 1)
        guard scaled.isFinite else { return "—" }
        let suffix = base == "bit" ? "b/s" : "B/s"
        let units = ["B", "KB", "MB", "GB", "TB"]
        let index = max(0, units.firstIndex(of: unit) ?? 0)
        let chosen = unit == "auto" ? min(4, max(0, Int(log(max(1, scaled)) / log(1000)))) : index
        let amount = scaled / pow(1000, Double(chosen))
        let number = amount.formatted(.number.precision(.fractionLength(amount < 10 && chosen > 0 ? 1 : 0)))
        let prefix = chosen == 0 ? "" : String(units[chosen].dropLast())
        return "\(number) \(prefix)\(suffix)"
    }

    static func text(_ template: String, volume: DiskVolume?) -> String {
        let total = volume?.totalBytes
        let free = volume?.freeBytes
        let used = total.flatMap { total in free.map { total >= $0 ? total - $0 : 0 } }
        let freeFraction = total.flatMap { total in
            total > 0 ? free.map { min(1, max(0, Double($0) / Double(total))) } : nil
        }
        let replacements = [
            "$capacity.free": MetricFormat.bytes(free),
            "$capacity.used": MetricFormat.bytes(used),
            "$capacity.total": MetricFormat.bytes(total),
            "$percentage.free": MetricFormat.percent(freeFraction),
            "$percentage.used": MetricFormat.percent(freeFraction.map { 1 - $0 })
        ]
        return replacements.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
