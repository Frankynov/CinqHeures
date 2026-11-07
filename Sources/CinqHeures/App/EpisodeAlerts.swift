import CinqHeuresCore
import Foundation
#if os(tvOS)
/// The Apple TV has no notifications to show: nothing to set up or announce.
@MainActor
final class EpisodeAlerts {
    static let shared = EpisodeAlerts()
    func setUp(open: @escaping (Int) -> Void) {}
    func announce(newIn catalogue: Catalogue) {}
}
#else
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// "Nouvel épisode" notifications for the two shows that still get new episodes, Hugues Dayez's
/// reviews and Il est toujours 5 heures quelque part.
///
/// Asked for quietly ("provisional"): no question when the app opens; the first ones go straight to
/// Notification Centre, where they can be kept (shown as banners from then on) or turned off. iPhone and
/// iPad check in the background when iOS lets the app (`refreshTask`), the Mac every hour while open.
/// Tapping one opens the episode.
@MainActor
final class EpisodeAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = EpisodeAlerts()
    static let shows: [Series] = [.dayez, .quelquePart]
    /// The background refresh's identifier, also listed in the iOS app's Info.plist.
    static let refreshTask = "be.cinqheures.player.refresh"

    /// Opens an episode by id (set by the model).
    var open: ((Int) -> Void)?

    func setUp(open: @escaping (Int) -> Void) {
        self.open = open
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    private static func seenKey(_ series: Series) -> String { "newestSeen.\(series.rawValue)" }

    /// Announces the episodes newer than the newest one seen before, a few per show at most. The first
    /// time (no record yet: a first launch, an update) it only remembers where things stand.
    func announce(newIn catalogue: Catalogue) {
        for series in Self.shows {
            let episodes = catalogue.episodes.filter { $0.series == series }
            guard let newest = episodes.map(\.date).max() else { continue }
            let key = Self.seenKey(series)
            defer { if newest.timeIntervalSince1970 > UserDefaults.standard.double(forKey: key) { UserDefaults.standard.set(newest.timeIntervalSince1970, forKey: key) } }
            guard UserDefaults.standard.object(forKey: key) != nil else { continue }
            let seen = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: key))
            for episode in episodes.filter({ $0.date > seen }).sorted(by: { $0.date > $1.date }).prefix(3) {
                post(episode)
            }
        }
    }

    private func post(_ episode: Episode) {
        let content = UNMutableNotificationContent()
        content.title = episode.series.fullTitle
        content.body = episode.name ?? episode.subjects.map(\.displayTitle).joined(separator: " · ")
        if content.body.isEmpty { content.body = "Nouvel épisode" }
        content.threadIdentifier = episode.series.rawValue
        content.userInfo = ["episode": episode.id]
        let request = UNNotificationRequest(identifier: "episode-\(episode.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// With the app in front: into Notification Centre only, no banner over what's being read.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["episode"] as? Int else { return }
        await MainActor.run { open?(id) }
    }

    // MARK: Background refresh (iPhone and iPad)

    #if os(iOS)
    /// Asks iOS for a refresh in an hour or more; iOS picks the moment (sooner for an app used often).
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
#endif
