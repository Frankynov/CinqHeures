import CinqHeuresCore
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Every film, series and person the shows discussed, and every episode, in the system's Spotlight:
/// typing "Oppenheimer" there lists the film, and picking it opens its page in the app.
///
/// Indexed again only when the catalogue changes (new episodes, a reset), in the background.
enum SpotlightIndex {
    private static let fingerprintKey = "spotlightFingerprint"
    /// Bumped when what's indexed changes, so every device indexes again once.
    private static let version = 1

    static func update(_ catalogue: Catalogue) {
        let fingerprint = "\(version)|\(catalogue.episodes.count)|\(catalogue.updatedAt?.timeIntervalSince1970 ?? 0)"
        guard UserDefaults.standard.string(forKey: fingerprintKey) != fingerprint, !catalogue.isEmpty else { return }
        Task.detached(priority: .background) {
            let items = makeItems(catalogue)
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteAllSearchableItems()
                for start in stride(from: 0, to: items.count, by: 500) {
                    try await index.indexSearchableItems(Array(items[start..<min(start + 500, items.count)]))
                }
                UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
            } catch {
                // Spotlight unavailable (indexing turned off): tried again at the next launch.
            }
        }
    }

    /// Forgets what was indexed, so the next catalogue is indexed afresh (Réinitialiser).
    static func reset() { UserDefaults.standard.removeObject(forKey: fingerprintKey) }

    private static func makeItems(_ catalogue: Catalogue) -> [CSSearchableItem] {
        // One item a film, series or person, from its newest passage, listing every show that discussed it.
        var works: [String: (segment: Segment, episodes: [Episode])] = [:]
        for episode in catalogue.episodes {
            for segment in episode.segments where segment.kind.isSubject {
                let key = workID(segment.kind, segment.title)
                if var entry = works[key] {
                    entry.episodes.append(episode)
                    if episode.date > entry.episodes[0].date { entry.segment = segment }
                    works[key] = entry
                } else {
                    works[key] = (segment, [episode])
                }
            }
        }
        var items: [CSSearchableItem] = works.map { id, entry in
            let segment = entry.segment
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = segment.displayTitle
            attributes.alternateNames = [segment.localTitle, segment.title].compactMap { $0 }.filter { $0 != segment.displayTitle }
            let newest = entry.episodes.max { $0.date < $1.date }!
            let facts = [segment.kind.label, segment.year.map(String.init), segment.director.map { "de \($0)" },
                         segment.stars.map(Segment.starString),
                         entry.episodes.count > 1 ? "\(entry.episodes.count) passages" : "\(newest.series.title), \(EpisodeDates.short.string(from: newest.date))"]
            attributes.contentDescription = facts.compactMap { $0 }.joined(separator: " · ")
            attributes.keywords = ["5 heures", "critique"] + Set(entry.episodes.map(\.series.title)) + [segment.director].compactMap { $0 }
            return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: "works", attributeSet: attributes)
        }
        for episode in catalogue.episodes {
            let attributes = CSSearchableItemAttributeSet(contentType: .audio)
            attributes.title = episode.title
            let subjects = episode.subjects.map(\.displayTitle)
            attributes.contentDescription = subjects.isEmpty
                ? [EpisodeDates.long.string(from: episode.date), String(episode.summary.prefix(200))].filter { !$0.isEmpty }.joined(separator: " · ")
                : subjects.joined(separator: " · ")
            attributes.keywords = [episode.series.title, "5 heures"]
            items.append(CSSearchableItem(uniqueIdentifier: "episode|\(episode.id)", domainIdentifier: "episodes", attributeSet: attributes))
        }
        return items
    }

    private static func workID(_ kind: SegmentKind, _ title: String) -> String { "work|\(kind.rawValue)|\(title)" }

    /// The page a Spotlight result opens.
    static func route(for activity: NSUserActivity) -> Route? {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
        switch parts.first {
        case "work" where parts.count == 3:
            return SegmentKind(rawValue: parts[1]).map { .work($0, parts[2]) }
        case "episode" where parts.count == 2:
            return Int(parts[1]).map { .episode($0, highlight: nil) }
        default:
            return nil
        }
    }
}
