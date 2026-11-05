import CinqHeuresCore
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The shortcuts in the app icon's menu: a long press on the home screen (iPhone, iPad), a right click
/// on the Dock icon (Mac). Four at most, iOS's limit.
enum QuickAction: String, CaseIterable {
    /// A well-rated review picked at random, played from its first word, with its film's page.
    case surprise
    /// The episode listened to last, from where it was left.
    case resume
    /// This week's Hugues Dayez.
    case dayez
    case search

    struct Item {
        let action: QuickAction
        let title: String
        let subtitle: String?
        let symbol: String
    }

    /// The model the shortcuts act on (there's one), set when it's made.
    @MainActor static weak var model: AppModel?
    /// A shortcut chosen before the model or its index was ready (the app was launched by it).
    @MainActor static var pending: QuickAction?

    @MainActor static func perform(_ action: QuickAction) {
        guard let model, model.isBrowsable else { pending = action; return }
        model.perform(action)
    }
}

extension AppModel {
    /// What the icon's menu offers now: "Reprendre" only with an episode in progress, under its name.
    var quickActionItems: [QuickAction.Item] {
        var items = [QuickAction.Item(action: .surprise, title: "Une critique au hasard", subtitle: "Écouter tout de suite", symbol: "dice.fill")]
        if let last = continueListening.first {
            items.append(.init(action: .resume, title: "Reprendre", subtitle: Spoken.title(last.episode), symbol: "play.fill"))
        }
        if let dayez = newestDayez {
            items.append(.init(action: .dayez, title: "Dernières critiques d'Hugues Dayez",
                               subtitle: dayez.subjects.map(\.displayTitle).joined(separator: " · "), symbol: "popcorn.fill"))
        }
        items.append(.init(action: .search, title: "Rechercher", subtitle: nil, symbol: "magnifyingglass"))
        return items
    }

    private var newestDayez: Episode? {
        catalogue.episodes.filter { $0.series == .dayez }.max { $0.date < $1.date }
    }

    func perform(_ action: QuickAction) {
        switch action {
        case .surprise:
            guard let pick = surprise() else { return }
            play(pick.episode, from: pick.segment)
            openFromOutside(.work(pick.segment.kind, pick.segment.title))
        case .resume:
            guard let last = continueListening.first else { return }
            play(last.episode)
            openFromOutside(.episode(last.episode.id, highlight: nil))
        case .dayez:
            guard let episode = newestDayez else { return }
            play(episode)
            openFromOutside(.episode(episode.id, highlight: nil))
        case .search:
            path = []
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { phoneTab = .search; return }
            #endif
            focusSearch()
        }
    }

    /// Runs a shortcut that came in while the app was still opening.
    func performPendingQuickAction() {
        guard let action = QuickAction.pending, isBrowsable else { return }
        QuickAction.pending = nil
        perform(action)
    }
}

#if os(iOS)
/// Hands the icon's shortcuts to the model: one that launched the app arrives with the new scene,
/// one chosen while it runs through the scene's delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem, let action = QuickAction(rawValue: item.type) {
            MainActor.assumeIsolated { QuickAction.perform(action) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        guard let action = QuickAction(rawValue: shortcutItem.type) else { return false }
        await MainActor.run { QuickAction.perform(action) }
        return true
    }
}

extension AppModel {
    /// Puts the menu's current items on the app icon (called as the app goes to the background).
    func updateQuickActions() {
        UIApplication.shared.shortcutItems = quickActionItems.map { item in
            UIApplicationShortcutItem(type: item.action.rawValue, localizedTitle: item.title, localizedSubtitle: item.subtitle,
                                      icon: UIApplicationShortcutIcon(systemImageName: item.symbol))
        }
    }
}
#else
/// The Dock icon's menu, built when it's opened.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = QuickAction.model else { return nil }
        let menu = NSMenu()
        for item in model.quickActionItems {
            let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.action.rawValue
            entry.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            if #available(macOS 14.4, *), let subtitle = item.subtitle, !subtitle.isEmpty { entry.subtitle = subtitle }
            menu.addItem(entry)
        }
        return menu
    }

    @MainActor @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = QuickAction(rawValue: raw) else { return }
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        QuickAction.perform(action)
    }
}
#endif
