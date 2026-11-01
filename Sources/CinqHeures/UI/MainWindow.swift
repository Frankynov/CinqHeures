import CinqHeuresCore
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel
    /// The content pane's width, so the player can sit over it alone and not over the sidebar.
    @ViewState private var contentWidth: CGFloat = 0
    /// Where the sidebar ends, in the window (iPad: the player starts there).
    @ViewState private var sidebarEdge: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            // iPhone: tabs, with the mini player above them (see PhoneTabs).
            PhoneTabs(model: model).modifier(AppBehaviors(model: model))
        } else {
            splitLayout
                // An iPad window widened out of the tabs: the split view shows Accueil's stack only, so
                // pages must now be pushed there. Left on Émissions or Recherche, taps on posters,
                // "Tout voir" or the player went to a stack nobody could see.
                .onAppear { model.phoneTab = .home }
        }
        #else
        splitLayout
        #endif
    }

    private var splitLayout: some View {
        // The player floats over the bottom of the pages, in glass; each page keeps room under its
        // last row (`pageEdges`) so nothing stays hidden behind it. It hangs off the whole window, not
        // the navigation stack: pushed pages are hosted on their own and would be drawn over it.
        columns
            .overlay(alignment: .bottomTrailing) {
                #if os(macOS)
                playerBar.frame(width: contentWidth > 0 ? contentWidth : nil)
                #else
                // iPad: from the sidebar's edge (it floats over the content column).
                playerBar.padding(.leading, sidebarEdge)
                #endif
            }
            .coordinateSpace(name: "window")
    }

    private var playerBar: some View {
        PlayerBar(player: model.player, open: { model.openCurrentEpisode() })
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }

    private var columns: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("window")).maxX } action: { sidebarEdge = max(0, $0) }
                .onDisappear { sidebarEdge = 0 }
        } detail: {
            // Each page handles its own edges (`pageEdges`): a modifier here would only reach the
            // root page, not the ones pushed on top of it.
            NavigationStack(path: $model.path) {
                root
                    .navigationDestination(for: Route.self) { destination($0) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Film, série, réalisateur, acteur, artiste…")
        .modifier(AppBehaviors(model: model))
        // No toolbar background. On macOS 26 the content column's toolbar band starts a few points
        // inside the sidebar, because content extends under it, so its edge doesn't line up with
        // the columns below. Without the band the column edges run cleanly to the top of the window.
        .hiddenWindowToolbarBackground()
    }

    /// The page the sidebar's selection (or a search) shows, before anything is pushed on it.
    @ViewBuilder private var root: some View {
        // Until the first index is ready the home page would be empty: show the download instead.
        if model.catalogue.isEmpty || (model.isSyncing && model.homeSections.isEmpty) {
            FirstLaunchView(model: model)
        } else if model.isSearching {
            SearchPage(model: model)
        } else {
            switch model.sidebar {
            case .home: HomeView(model: model)
            case .all: ShowPage(series: nil, model: model)
            case .show(let series): ShowPage(series: series, model: model)
            case .score(let stars): ListingPage(listing: .stars(stars), model: model)
            case .unrated: ListingPage(listing: .unrated, model: model)
            }
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        RoutePage(route: route, model: model)
    }
}

/// The page a route leads to, wherever it's pushed (the content column, or an iPhone tab).
struct RoutePage: View {
    let route: Route
    let model: AppModel

    var body: some View {
        switch route {
        case .work(let kind, let title): WorkPage(kind: kind, title: title, model: model)
        case .episode(let id, let highlight): EpisodePage(id: id, highlight: highlight, model: model)
        case .listing(let listing): ListingPage(listing: listing, model: model)
        case .show(let series): ShowPage(series: series, model: model)
        case .recent: ShowPage(series: nil, model: model)
        }
    }
}

/// What the window does whatever its layout: run searches, refresh the feeds, offer the reset sheet.
struct AppBehaviors: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.searchText) {
                if model.isSearching { model.popToRoot() }
                model.searchChanged()
            }
            .onChange(of: model.scope) { model.searchChanged(typing: false) }
            .onChange(of: model.sidebar) {
                model.popToRoot()
                model.searchChanged(typing: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .appBecameActive)) { _ in
                model.updateCacheUsage()
                Task { await model.refreshFeed() }
            }
            .sheet(isPresented: $model.showsReset) { ResetSheet(model: model) }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        // On the Mac a row always stays selected; on iPhone going back from a page empties the
        // selection, which is what shows the list again.
        #if os(macOS)
        let selection = Binding<SidebarItem?>(get: { model.sidebar }, set: { if let item = $0 { model.sidebar = item } })
        #else
        let selection = $model.sidebarSelection
        #endif
        List(selection: selection) {
            Label { Text("Accueil") } icon: { SidebarIcon(symbol: "house.fill", color: .blue) }
                .tag(SidebarItem.home)
            Section("Émissions") {
                Label {
                    // Every episode of every show, newest first.
                    Text("Récents")
                } icon: {
                    SidebarIcon(symbol: "clock.fill", color: .gray)
                }
                .badge(model.count(of: nil))
                .tag(SidebarItem.all)
                ForEach(Series.allCases) { series in
                    Label {
                        Text(series.title).lineLimit(2)
                    } icon: {
                        SidebarIcon(symbol: series.symbol, color: series.tint, inset: series == .codLive ? 2.5 : 4)
                    }
                    .badge(model.count(of: series))
                    .tag(SidebarItem.show(series))
                }
            }
            Section("Notes des films") {
                ForEach([4, 3, 2, 1, 0], id: \.self) { stars in
                    Label {
                        Text(Segment.starString(stars))
                            .foregroundStyle(stars >= 3 ? Color.orange : Color.secondary)
                    } icon: {
                        SidebarNumber(number: stars, color: stars >= 3 ? brandOrange : .gray)
                    }
                    .badge(model.count(ofStars: stars))
                    .accessibilityLabel("\(stars) étoile\(stars > 1 ? "s" : "") sur 4")
                    .tag(SidebarItem.score(stars))
                }
                Label {
                    Text("Sans note").foregroundStyle(.secondary)
                } icon: {
                    SidebarIcon(symbol: "minus", color: .gray)
                }
                .badge(model.unratedCount)
                .tag(SidebarItem.unrated)
            }
            #if os(iOS)
            Section { ResetButton(model: model) }
            // At the end of the list, scrolling with it: as a bar it covered the last rows.
            Section { SyncStatus(model: model) }
                .listRowBackground(Color.clear)
            #endif
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom) { SyncStatus(model: model) }
        #endif
    }
}

struct SyncStatus: View {
    let model: AppModel

    var body: some View {
        switch model.sync {
        case .idle:
            if let date = model.catalogue.updatedAt {
                Text("À jour au \(EpisodeDates.short.string(from: date))")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("Téléchargement du catalogue…").font(.caption)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
            }
            .padding(10)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Hors ligne ou site indisponible", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Text(message).font(.caption2).foregroundStyle(.secondary)
                Button("Réessayer") {
                    Task { await model.refresh(everything: model.catalogue.isEmpty || model.catalogue.needsFullDownload) }
                }
                    .controlSize(.small)
            }
            .padding(10)
        }
    }
}

#if os(iOS)
/// The Mac's "Réinitialiser…" menu item, as a row at the end of the iPad sidebar and the iPhone's Émissions.
struct ResetButton: View {
    let model: AppModel

    var body: some View {
        Button {
            model.updateCacheUsage()
            model.showsReset = true
        } label: {
            Label {
                Text("Réinitialiser…")
                Text("Cache : \(CacheUsage.text(model.cacheUsage.total))").foregroundStyle(.secondary)
            } icon: {
                SidebarIcon(symbol: "arrow.counterclockwise", color: .gray)
            }
        }
        .foregroundStyle(.primary)
    }
}
#endif

/// "Réinitialiser": the cache and the listening progress as two checkboxes, ticked in any combination.
struct ResetSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var cache = true
    @ViewState private var progress = false

    var body: some View {
        let usage = model.cacheUsage
        let inProgress = model.continueListening.count
        VStack(alignment: .leading, spacing: 18) {
            Text("Réinitialiser").font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 14) {
                choice($cache, title: "Cache · \(CacheUsage.text(usage.total))",
                       detail: "Catalogue (\(CacheUsage.text(usage.catalogue))) et affiches (\(CacheUsage.text(usage.posters))). "
                             + "L'app retélécharge ensuite le catalogue depuis 5heures.be, comme à la première ouverture.")
                    .disabled(model.isSyncing)
                choice($progress, title: "Progression d'écoute · \(inProgress) épisode\(inProgress > 1 ? "s" : "") en cours",
                       detail: "Les positions de reprise et la rangée « Continuer l'écoute ». Le cache n'est pas touché.")
            }

            #if os(macOS)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                eraseButton
                    .keyboardShortcut(.defaultAction)
            }
            #else
            // A sheet is dismissed by swiping it down: no Annuler, one full-width button.
            eraseButton
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            #endif
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: 480, alignment: .leading)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear {
            model.updateCacheUsage()
            if model.isSyncing { cache = false }
        }
    }

    private var eraseButton: some View {
        Button(role: .destructive) {
            let (cache, progress) = (cache, progress)
            dismiss()
            Task { await model.reset(cache: cache, progress: progress) }
        } label: {
            Text("Effacer")
                #if os(iOS)
                .frame(maxWidth: .infinity)
                #endif
        }
        .disabled(!cache && !progress)
    }

    private func choice(_ isOn: Binding<Bool>, title: String, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .checkboxStyle()
    }
}
