import Foundation
import Testing
@testable import CinqHeuresCore

private func fixtureEpisodes() throws -> [Episode] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/episodes.json")
    let page = try JSONDecoder().decode(WirePage.self, from: Data(contentsOf: url))
    return page.podcasts.compactMap(\.episode)
}

@Suite struct DecodingTests {
    @Test func everyShowIsRecognised() throws {
        let episodes = try fixtureEpisodes()
        #expect(episodes.count == 6)
        #expect(Set(episodes.map(\.series)) == Set(Series.allCases.filter(\.isOnSite)))   // the music podcast isn't on the site
    }

    /// The API's `available_at` of the Substance episode is 2024-12-04; it was recorded on 4 November.
    @Test func dateComesFromTheEpisodeTitleNotTheAPIDate() throws {
        let substance = try #require(fixtureEpisodes().first { $0.id == 1449 })
        #expect(EpisodeDates.short.string(from: substance.date) == "04/11/2024")
        #expect(substance.title == "Podcast du 04/11/2024")
    }

    @Test func segmentsKeepTheirTimecodeAndVerdict() throws {
        let substance = try #require(fixtureEpisodes().first { $0.id == 1449 })
        let review = try #require(substance.segments.first { $0.title == "The Substance (2024)" })
        #expect(review.kind == .movie)
        #expect(review.start == 860)
        #expect(review.verdict == "4 bonnes doses")
    }

    @Test func introductionIsNotASubject() throws {
        let episode = try #require(fixtureEpisodes().first { $0.id == 1613 })
        #expect(episode.segments.first?.kind == .introduction)
        #expect(episode.subjects.map(\.title).contains("KPop Demon Hunters (2025)"))
        #expect(!episode.subjects.contains { $0.kind == .introduction || $0.kind == .conclusion })
    }

    @Test func anEpisodeWithoutAudioIsSkipped() throws {
        let json = #"{"id":1,"kind":"cinq_heures","display_name":"Podcast du 01/01/2020","available_at":"2020-02-01","parts":[]}"#
        let episode = try JSONDecoder().decode(WireEpisode.self, from: Data(json.utf8))
        #expect(episode.episode == nil)
    }
}

@Suite struct SearchTests {
    let catalogue: Catalogue

    init() throws { catalogue = Catalogue(episodes: try fixtureEpisodes()) }

    @Test func foldingIgnoresAccentsCaseAndPunctuation() {
        #expect(Search.fold("Amélie  et-la MÉTAPHYSIQUE") == "amelie et la metaphysique")
        #expect(Search.fold("  ") == "")
    }

    @Test func findsAFilmWithoutItsYearOrAccents() {
        let works = Search.works(matching: "substance", in: catalogue)
        #expect(works.first?.title == "The Substance (2024)")
        #expect(works.first?.mentions.first?.segment.start == 860)
        #expect(Search.works(matching: "ACCIDENT DE PIANO", in: catalogue).first?.title == "L'Accident de piano (2025)")
    }

    @Test func everyWordMustMatch() {
        #expect(Search.works(matching: "twin peaks fire", in: catalogue).count == 1)
        #expect(Search.works(matching: "twin banana", in: catalogue).isEmpty)
    }

    @Test func seriesAreFoundToo() {
        let all = Search.works(matching: "severance", in: catalogue)
        #expect(all.first?.kind == .tvShow)
        #expect(Search.works(matching: "severance", in: catalogue, scope: .shows).count == 1)
        #expect(Search.works(matching: "severance", in: catalogue, scope: .movies).isEmpty)
    }

    @Test func canBeLimitedToOneShow() {
        #expect(Search.works(matching: "twin peaks", in: catalogue, series: [.codLive]).count == 1)
        #expect(Search.works(matching: "twin peaks", in: catalogue, series: [.podcast]).isEmpty)
    }

    /// A film discussed twice gives one work with two mentions, newest first.
    @Test func aFilmDiscussedTwiceIsOneWorkWithTwoMentions() throws {
        let original = try #require(catalogue.episodes.first { $0.id == 1449 })
        let segment = try #require(original.segments.first { $0.title == "The Substance (2024)" })
        let later = Episode(id: 9999, series: .soir, date: original.date.addingTimeInterval(86_400 * 30),
                            summary: "", audioURL: original.audioURL, segments: [segment])
        var catalogue = catalogue
        catalogue.merge([later])
        let work = try #require(Search.works(matching: "the substance", in: catalogue).first)
        #expect(work.mentions.map(\.episode.id) == [9999, 1449])
    }

    @Test func exactTitlesComeBeforePartialOnes() {
        let works = Search.works(matching: "the", in: catalogue)
        #expect(works.count > 1)
        #expect(works.first.map { Search.fold($0.title).hasPrefix("the") } == true)
    }
}

@Suite struct CatalogueTests {
    @Test func mergeReplacesKnownEpisodesAndSortsNewestFirst() throws {
        var catalogue = Catalogue(episodes: try fixtureEpisodes())
        let dates = catalogue.episodes.map(\.date)
        #expect(dates == dates.sorted(by: >))
        let count = catalogue.episodes.count
        catalogue.merge(Array(catalogue.episodes.prefix(2)))
        #expect(catalogue.episodes.count == count)
    }

    /// The home page draws its shelves from the catalogue in order: episodes recorded the same day must
    /// keep one order whatever order they come in, or a refresh with nothing new reshuffles it.
    @Test func sameDayEpisodesAlwaysComeInTheSameOrder() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let episodes = (1...6).map { id in
            Episode(id: id, series: .podcast, date: id == 6 ? day.addingTimeInterval(86_400) : day, summary: "",
                    audioURL: URL(string: "https://example.com/\(id).mp3")!, segments: [])
        }
        let expected = [6, 5, 4, 3, 2, 1]
        #expect(Catalogue(episodes: episodes).episodes.map(\.id) == expected)
        #expect(Catalogue(episodes: episodes.reversed()).episodes.map(\.id) == expected)
        var merged = Catalogue(episodes: Array(episodes.prefix(3)))
        merged.merge(episodes.shuffled())
        #expect(merged.episodes.map(\.id) == expected)
        merged.replaceEpisodes(of: .podcast, with: episodes.shuffled())
        #expect(merged.episodes.map(\.id) == expected)
    }

    @Test func savesAndLoadsBack() throws {
        let catalogue = Catalogue(episodes: try fixtureEpisodes(), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try catalogue.save(to: url)
        let loaded = try #require(Catalogue.load(from: url))
        #expect(loaded.episodes == catalogue.episodes)
        #expect(loaded.updatedAt == catalogue.updatedAt)
    }
}

@Suite struct SearchIndexTests {
    @Test func indexAndDirectSearchAgree() throws {
        let catalogue = Catalogue(episodes: try fixtureEpisodes())
        let index = SearchIndex(catalogue)
        for query in ["the", "twin peaks", "Amélie", "severance", "zzz"] {
            #expect(index.works(matching: query).map(\.id) == Search.works(matching: query, in: catalogue).map(\.id))
        }
    }

    @Test func descriptionsAreSearchedToo() throws {
        let index = SearchIndex(Catalogue(episodes: try fixtureEpisodes()))
        #expect(index.episodes(describedBy: "dupieux").map(\.id) == [1613])
    }

    /// Typing must stay instant: on the real catalogue (skipped when the app has never run here)
    /// every query takes a few milliseconds once the index exists.
    @Test func searchingTheRealCatalogueIsFast() throws {
        guard let catalogue = Catalogue.load(from: Catalogue.defaultLocation), catalogue.episodes.count > 1000 else { return }
        let built = ContinuousClock().measure { _ = SearchIndex(catalogue) }
        let index = SearchIndex(catalogue)
        var slowest = Duration.zero
        for query in ["t", "the", "twin peaks", "amélie", "black mirror", "dupieux"] {
            let time = ContinuousClock().measure {
                _ = index.works(matching: query)
                _ = index.episodes(describedBy: query)
            }
            slowest = max(slowest, time)
            print("search '\(query)': \(time)")
        }
        print("index built in \(built); slowest query \(slowest)")
        #expect(slowest < .milliseconds(150))
    }
}

@Suite struct ScoreTests {
    @Test func theNumberIsReadFromWhateverTheHostsWrote() {
        #expect(Segment.parseScore("4") == 4)
        #expect(Segment.parseScore("2 ") == 2)
        #expect(Segment.parseScore("1,5") == 1.5)
        #expect(Segment.parseScore("3 porte-avions") == 3)
        #expect(Segment.parseScore("Pas de cotation") == nil)
        #expect(Segment.parseScore("Pas rattrapé") == nil)
        #expect(Segment.parseScore("") == nil)
        #expect(Segment.parseScore(nil) == nil)
    }

    @Test func starsAreWholeAndClampedToFour() {
        func stars(_ score: Double?) -> Int? {
            Segment(id: 0, title: "", kind: .movie, start: nil, verdict: nil, score: score, posterURL: nil).stars
        }
        #expect(stars(1.5) == 1)
        #expect(stars(4) == 4)
        #expect(stars(5) == 4)
        #expect(stars(0) == 0)
        #expect(stars(nil) == nil)
        #expect(Segment.starString(3) == "★★★☆")
    }

    @Test func scoreComesFromTheEpisodeData() throws {
        let substance = try #require(fixtureEpisodes().first { $0.id == 1449 })
        let review = try #require(substance.segments.first { $0.title == "The Substance (2024)" })
        #expect(review.score == 4)
        #expect(review.stars == 4)
        #expect(review.spokenVerdict == "4 bonnes doses")
    }

    @Test func listsEveryPassageWithAScoreNewestFirstWithoutAQuery() throws {
        let index = SearchIndex(Catalogue(episodes: try fixtureEpisodes()))
        let four = index.works(matching: "", stars: 4)
        #expect(four.map(\.title).contains("The Substance (2024)"))
        #expect(four.allSatisfy { $0.mentions.allSatisfy { $0.segment.stars == 4 } })
        #expect(index.works(matching: "").isEmpty)           // no query and no score: nothing
        #expect(index.works(matching: "substance", stars: 1).isEmpty)
        #expect(index.works(matching: "substance", stars: 4).count == 1)
    }

    @Test func oldSavedCatalogueIsDownloadedAgain() throws {
        let json = #"{"episodes":[]}"#
        let old = try JSONDecoder().decode(Catalogue.self, from: Data(json.utf8))
        #expect(old.needsFullDownload)
        var fresh = Catalogue()
        #expect(!fresh.needsFullDownload)
        fresh = old
        fresh.markDownloadedInFull()
        #expect(!fresh.needsFullDownload)
    }
}

@Suite struct FeedTests {
    private func feedEpisodes() throws -> [Episode] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/feed.xml")
        return try FeedClient.episodes(from: Data(contentsOf: url))
    }

    @Test func readsEpisodesNewestFirstAndSkipsOnesWithoutAudio() throws {
        let episodes = try feedEpisodes()
        #expect(episodes.count == 6)                                   // the 7th has no audio file
        #expect(episodes.map(\.date) == episodes.map(\.date).sorted(by: >))
        #expect(episodes.allSatisfy { $0.series == .quelquePart && $0.segments.isEmpty })
        #expect(episodes.first?.name == "Halloween Mixtape")
        #expect(episodes.first?.audioURL.host == "audio.ausha.co")
        #expect(episodes.first?.duration == 4987)                      // 1:23:07
    }

    @Test func idsAreStableAndNeverClashWithTheSitesOwn() throws {
        let first = try feedEpisodes(), second = try feedEpisodes()
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.allSatisfy { $0.id < 0 })
        #expect(Set(first.map(\.id)).count == first.count)
    }

    @Test func coversUseTheSmallVersion() throws {
        let cover = try #require(feedEpisodes().first?.artwork)
        #expect(cover.absoluteString.contains("_400x400"))
    }

    @Test func durationsAreReadInEveryFormat() {
        #expect(FeedClient.parseDuration("1:23:07") == 4987)
        #expect(FeedClient.parseDuration("04:22") == 262)
        #expect(FeedClient.parseDuration("3600") == 3600)
        #expect(FeedClient.parseDuration("n/a") == nil)
    }

    @Test func theTitleIsSearchable() throws {
        let index = SearchIndex(Catalogue(episodes: try feedEpisodes()))
        #expect(index.episodes(describedBy: "halloween").count == 1)
        #expect(index.episodes(describedBy: "episode 44").count == 1)
    }

    @Test func theShowDoesNotUseTheSitesSlowServerWorkaround() {
        #expect(Series.quelquePart.isOnSite == false)
        #expect(Series.podcast.isOnSite)
    }
}

@Suite struct DiscoveryTests {
    let catalogue: Catalogue

    init() throws { catalogue = Catalogue(episodes: try fixtureEpisodes()) }

    private func segment(_ title: String) -> Segment {
        Segment(id: 0, title: title, kind: .movie, start: nil, verdict: nil, posterURL: nil)
    }

    @Test func theYearIsReadFromTheTitle() {
        #expect(segment("Oblivion (2013)").year == 2013)
        #expect(segment("Oblivion (2013)").displayTitle == "Oblivion")
        #expect(segment("Black Mirror").year == nil)
        #expect(segment("Black Mirror").displayTitle == "Black Mirror")
        #expect(segment("(500) jours ensemble (2009)").year == 2009)
        #expect(segment("(500) jours ensemble (2009)").displayTitle == "(500) jours ensemble")
        #expect(segment("Blade Runner 2049").year == nil)
        #expect(segment("Oblivion (2013) ").displayTitle == "Oblivion")
        #expect(segment("Film (20133)").year == nil)
    }

    /// The year is read by hand for speed: it must say exactly what the regular expressions it
    /// replaced said, on every title of the fixture and on the odd ones.
    @Test func theYearReaderAgreesWithTheRegularExpressions() throws {
        func regexYear(_ title: String) -> Int? {
            guard let range = title.range(of: #"\((\d{4})\)\s*$"#, options: .regularExpression) else { return nil }
            return Int(title[range].filter(\.isNumber))
        }
        func regexDisplayTitle(_ title: String) -> String {
            regexYear(title) == nil ? title
                : title.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
        }
        let odd = ["Oblivion (2013)", "Oblivion(2013)", "Oblivion  (2013)  ", "Oblivion (2013)\n", "(2013)", "Film (13)",
                   "Film (20133)", "Film 2013)", "Film (2013", "Film (2013) suite", "Amélie (2001)", "Été 85 (2020)",
                   "Film\u{00A0}(2013)", "Film (٢٠١٣)", "", " ", "()", "Film (2O13)", "M (1931)", "Film (1999) (2000)"]
        let titles = odd + catalogue.episodes.flatMap(\.segments).map(\.title)
        for title in titles {
            #expect(segment(title).year == regexYear(title), "year of \(title.debugDescription)")
            #expect(segment(title).displayTitle == regexDisplayTitle(title), "display title of \(title.debugDescription)")
        }
    }

    @Test func decadesGroupFilmsByTheirReleaseYear() {
        #expect(Decade.of(year: 1959) == 0)
        #expect(Decade.of(year: 1986) == 1980)
        #expect(Decade.of(year: 2024) == 2020)
        #expect(Decade.title(1980) == "Années 80")
        #expect(Decade.title(2000) == "Années 2000")
        #expect(Decade.title(0) == "Avant 1960")
    }

    @Test func aListingHoldsOnePassagePerFilm() {
        let discovery = Discovery(catalogue)
        let titles = discovery.items(.latest).compactMap { item -> String? in
            if case .passage(let m) = item { m.segment.title } else { nil }
        }
        #expect(!titles.isEmpty)
        #expect(Set(titles).count == titles.count)
    }

    @Test func starListingsOnlyHoldThatScore() {
        let discovery = Discovery(catalogue)
        let fours = discovery.items(.stars(4))
        #expect(!fours.isEmpty)
        #expect(fours.allSatisfy { if case .passage(let m) = $0 { m.segment.stars == 4 } else { false } })
    }

    @Test func unratedHoldsOnlyFilmsWithoutAScore() {
        let unrated = Discovery(catalogue).items(.unrated)
        #expect(!unrated.isEmpty)
        #expect(unrated.allSatisfy { if case .passage(let m) = $0 { m.segment.stars == nil && m.segment.kind == .movie } else { false } })
    }

    @Test func theSameSeedGivesTheSameShelves() {
        let discovery = Discovery(catalogue)
        let a = discovery.shelves(seed: 42).map { $0.items.map(\.id) }
        let b = discovery.shelves(seed: 42).map { $0.items.map(\.id) }
        #expect(a == b)
        #expect(discovery.shelves(seed: 42).allSatisfy { !$0.items.isEmpty })
        #expect(!discovery.shelves(seed: 42).contains { $0.id == "latest" })   // the archive is frozen: no "latest" shelf
    }

    @Test func decadeTilesCountTheirFilms() {
        let tiles = Discovery(catalogue).decadeTiles(seed: 1)
        #expect(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.count > 0 })
        let total = tiles.reduce(0) { $0 + $1.count }
        let films = Discovery(catalogue).items(.latest).count
        #expect(total <= films)
    }

    @Test func theHeroIsAWellRatedFilmWithAPoster() throws {
        let hero = try #require(Discovery(catalogue).hero(seed: 3))
        #expect((hero.segment.stars ?? 0) >= 3)
        #expect(hero.segment.posterURL != nil)
    }

    @Test func aWorkIsFoundByKindAndTitle() throws {
        let index = SearchIndex(catalogue)
        let work = try #require(index.work(kind: .movie, title: "The Substance (2024)"))
        #expect(work.mentions.count == 1)
        #expect(index.work(kind: .tvShow, title: "The Substance (2024)") == nil)
    }

    /// The home page is rebuilt on the main thread (at launch, after each catalogue or film-details
    /// update, on "Surprenez-moi"), and a listing page sorts its titles on the main thread: on the real
    /// catalogue (skipped when the app has never run here) both must stay well under a few frames.
    @Test func browsingTheRealCatalogueIsFast() throws {
        guard let catalogue = Catalogue.load(from: Catalogue.defaultLocation), catalogue.episodes.count > 1000 else { return }
        let discovery = Discovery(catalogue)
        let clock = ContinuousClock()
        let home = clock.measure {
            _ = discovery.shelves(seed: 1)
            _ = discovery.decadeTiles(seed: 1)
            _ = discovery.hero(seed: 1)
        }
        let biggest = Decade.all.map { discovery.items(.decade($0)) }.max { $0.count < $1.count } ?? []
        func name(_ item: ShelfItem) -> String {
            if case .passage(let mention) = item { mention.segment.displayTitle } else { "" }
        }
        let byName = clock.measure {
            _ = biggest.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
        print("home rebuilt in \(home); \(biggest.count) films of one decade sorted by name in \(byName)")
    }
}

@Suite struct RobustDecodingTests {
    /// One broken episode (and one broken segment, and some junk values) must not sink the whole page.
    @Test func badEntriesAreSkippedNotFatal() throws {
        let json = #"""
        {"pagination": {"total_pages": 1}, "podcasts": [
          {"id": 1, "kind": "cinq_heures", "display_name": "Podcast du 01/02/2020",
           "audio_file_url": "https://example.com/a.mp3",
           "parts": [
             {"id": 10, "display_name": "Good (2019)", "kind": "movie", "start_second": 120, "score": "3", "score_text": "3 étoiles"},
             {"id": "not a number", "kind": "movie"},
             42,
             {"id": 11, "display_name": "Also good", "kind": "tv_show", "start_second": null, "score": 2}
           ]},
          {"id": "broken episode"},
          null,
          "junk",
          {"id": 2, "kind": "cod_live", "display_name": "Podcast du 03/04/2018",
           "audio_file_url": "https://example.com/b.mp3", "parts": []}
        ]}
        """#
        let page = try JSONDecoder().decode(WirePage.self, from: Data(json.utf8))
        let episodes = page.podcasts.compactMap(\.episode)
        #expect(episodes.map(\.id) == [1, 2])
        #expect(episodes[0].segments.map(\.id) == [10, 11])
        #expect(episodes[0].segments[1].score == 2)                 // a number, not a string
    }

    @Test func mergingKeepsTheNewerCopyOfAnEpisode() throws {
        var catalogue = Catalogue(episodes: try fixtureEpisodes())
        let original = try #require(catalogue.episodes.first)
        let renamed = Episode(id: original.id, series: original.series, date: original.date, summary: "updated",
                              audioURL: original.audioURL, segments: original.segments)
        catalogue.merge([renamed, renamed])
        #expect(catalogue.episodes.filter { $0.id == original.id }.map(\.summary) == ["updated"])
    }
}

@Suite struct DayezFeedTests {
    @Test func filmTitlesAreReadWhicheverWayTheTitleIsWritten() {
        #expect(FeedClient.filmTitles(in: "Coward - Wicker - Karma") == ["Coward", "Wicker", "Karma"])
        #expect(FeedClient.filmTitles(in: #""Les Misérables", "Le Corset", "Franz""#) == ["Les Misérables", "Le Corset", "Franz"])
        #expect(FeedClient.filmTitles(in: #""The Social Reckoning" - "Ni vue, ni connue" - "Fausse Note""#)
                == ["The Social Reckoning", "Ni vue, ni connue", "Fausse Note"])
        #expect(FeedClient.filmTitles(in: "Digger, Notre Salut et Verity") == ["Digger", "Notre Salut", "Verity"])
        #expect(FeedClient.filmTitles(in: #""Downton Abbey, le grand final" ; "Sirat"  et  " Miroirs n°3 ""#)
                == ["Downton Abbey, le grand final", "Sirat", "Miroirs n°3"])
        #expect(FeedClient.filmTitles(in: #"Cinéma, avec Hugues Dayez - "Un simple accident"-"Rembrandt"-"LHomme qui a vu l'ours qui a vu l'homme" - 01/10/2025"#)
                == ["Un simple accident", "Rembrandt", "LHomme qui a vu l'ours qui a vu l'homme"])
        #expect(FeedClient.filmTitles(in: "Cinéma : Moulin - La Gradiva - The only living pickpocket in New York")
                == ["Moulin", "La Gradiva", "The only living pickpocket in New York"])
        // The odd ones in the real feed.
        #expect(FeedClient.filmTitles(in: "Les chroniques de la Grande matinée, avec Hugues Dayez - Cinéma : Raisons et Sentiments-Garance-Chopin, Chopin! - 23/09/2026")
                == ["Raisons et Sentiments", "Garance", "Chopin, Chopin!"])
        #expect(FeedClient.filmTitles(in: #""Le chant des Forêts", 'A pied d'oeuvre", 'L'enfant bélier""#)
                == ["Le chant des Forêts", "A pied d'oeuvre", "L'enfant bélier"])
        #expect(FeedClient.filmTitles(in: "Tron: Arès / Mary Anning, film d'animation / The end avec Tilda Swinton")
                == ["Tron: Arès", "Mary Anning", "The end"])
        #expect(FeedClient.filmTitles(in: "The Death of Robin Hood de Michael Sarnoski") == ["The Death of Robin Hood"])
        #expect(FeedClient.filmTitles(in: "La voix de Hind Rajab - Misérables - Running man")
                == ["La voix de Hind Rajab", "Misérables", "Running man"])
        #expect(FeedClient.filmTitles(in: "l'homme qui rétrécit - Interview jean dujardin-mp3") == ["l'homme qui rétrécit"])
        #expect(FeedClient.filmTitles(in: "Linterview de Sophie Marceau pour LOL 2.0").isEmpty)
        #expect(FeedClient.filmTitles(in: #""Marsupilami", et si le cinéma arrêtait de massacrer Franquin ?"#) == ["Marsupilami"])
    }

    @Test func episodesCarryTheirFilmsAndPlayFromTheStart() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dayez.xml")
        let episodes = try FeedClient.episodes(from: Data(contentsOf: url), series: .dayez)
        #expect(episodes.count == 8)
        #expect(episodes.allSatisfy { $0.series == .dayez && !$0.isOnSiteServer })
        let coward = try #require(episodes.first { $0.segments.map(\.title).contains("Coward") })
        #expect(coward.subjects.count == 3)
        #expect(coward.segments.allSatisfy { $0.start == nil && $0.kind == .movie })
        #expect(coward.name == "Coward · Wicker · Karma")
        #expect(coward.summary.contains("Lucas Dont"))                 // the director, from the description
        #expect(episodes.allSatisfy { !$0.summary.hasPrefix("cinema-sorties") })
        // The title's own date wins over a wrong publication date (01/01/2025 in the feed).
        let accident = try #require(episodes.first { $0.segments.map(\.title).contains("Rembrandt") })
        #expect(EpisodeDates.short.string(from: accident.date) == "01/10/2025")
        // Searchable alongside everything else.
        let index = SearchIndex(Catalogue(episodes: episodes))
        #expect(index.works(matching: "wicker").first?.mentions.first?.episode.series == .dayez)
        #expect(Set(episodes.flatMap(\.segments).map(\.id)).count == episodes.flatMap(\.segments).count)
    }
}

private extension Episode {
    var isOnSiteServer: Bool { series.isOnSite }
}

@Suite struct FeedRefreshTests {
    @Test func aFeedRefreshReplacesThatShowOnly() throws {
        let site = try fixtureEpisodes()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dayez.xml")
        let dayez = try FeedClient.episodes(from: Data(contentsOf: url), series: .dayez)
        var catalogue = Catalogue(episodes: site + dayez)
        // A stale copy under another id, as an id-scheme change would leave behind.
        let stale = Episode(id: -42, series: .dayez, date: Date(), summary: "", audioURL: dayez[0].audioURL, segments: [])
        catalogue.merge([stale])
        catalogue.replaceEpisodes(of: .dayez, with: dayez)
        #expect(catalogue.episodes.filter { $0.series == .dayez }.count == dayez.count)
        #expect(catalogue.episodes.filter { $0.series.isOnSite }.count == site.filter { $0.series.isOnSite }.count)
    }

    @Test func theMusicPodcastKeepsItsIds() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/feed.xml")
        let episodes = try FeedClient.episodes(from: Data(contentsOf: url))
        #expect(episodes.first?.id == FeedClient.stableID("d32384faf19616ab609832fbda64a126f80f4cc0"))
    }
}


@Suite struct TMDBMatchingTests {
    @Test func titlesAreComparedGenerously() {
        #expect(TMDBClient.similarity(of: "Fausse Note", to: ["Fausse note"]) == 10)
        #expect(TMDBClient.similarity(of: "LHomme qui a vu l'ours qui a vu l'homme", to: ["L'Homme qui a vu l'ours qui a vu l'homme"]) == 10)
        #expect(TMDBClient.similarity(of: "Miroirs n°3", to: ["Miroirs No. 3"]) == 6)
        #expect(TMDBClient.similarity(of: "Downton Abbey, le grand final", to: ["Downton Abbey III : Le Grand Final"]) == 6)
        #expect(TMDBClient.similarity(of: "Beginnings", to: ["Transformers: Beginnings"]) == 6)
        #expect(TMDBClient.similarity(of: "Karma", to: ["Garance"]) == 0)
    }

    @Test func filmsInAnotherScriptKeepTheirFrenchTitle() {
        let chinese = FilmInfo(tmdbID: 1, title: "Résurrection", originalTitle: "狂野时代", year: 2025, overview: "", posterPath: nil, director: nil)
        #expect(chinese.archiveTitle == "Résurrection (2025)")
        let accented = FilmInfo(tmdbID: 2, title: "Sirat", originalTitle: "Sirāt", year: 2025, overview: "", posterPath: nil, director: nil)
        #expect(accented.archiveTitle == "Sirāt (2025)")
    }

    @Test func aDayezEpisodeTakesTMDBsTitlePosterAndSynopsis() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dayez.xml")
        let episode = try #require(FeedClient.episodes(from: Data(contentsOf: url), series: .dayez).first { $0.spokenFilms.contains("Coward") })
        var library = FilmLibrary()
        library.record(FilmInfo(tmdbID: 9, title: "Les Braves", originalTitle: "Coward", year: 2026, overview: "1916…",
                                posterPath: "/x.jpg", director: "Lukas Dhont"), title: "Coward", date: episode.date)
        library.record(nil, title: "Wicker", date: episode.date)
        let enriched = library.enrich(episode)
        #expect(enriched.segments[0].title == "Coward (2026)")
        #expect(enriched.segments[0].localTitle == "Les Braves")
        #expect(enriched.segments[0].posterURL?.absoluteString == "https://image.tmdb.org/t/p/w500/x.jpg")
        #expect(enriched.segments[0].director == "Lukas Dhont")
        #expect(enriched.segments[1].title == "Wicker")                          // not found: left as it was
        #expect(library.enrich(enriched).segments[0].title == "Coward (2026)")    // enriching twice changes nothing
        #expect(!library.needsLookup(title: "Wicker", date: episode.date))       // tried this week
        #expect(library.needsLookup(title: "Wicker", date: episode.date, now: Date().addingTimeInterval(8 * 86_400)))

        // A new release not found yet is asked about again within the day; an old film, a week later.
        let thisWeek = Date()
        var fresh = FilmLibrary()
        fresh.record(nil, title: "Moulin", date: thisWeek, at: thisWeek)
        #expect(!fresh.needsLookup(title: "Moulin", date: thisWeek, now: thisWeek.addingTimeInterval(3600)))
        #expect(fresh.needsLookup(title: "Moulin", date: thisWeek, now: thisWeek.addingTimeInterval(7 * 3600)))
        let longAgo = thisWeek.addingTimeInterval(-400 * 86_400)
        fresh.record(nil, title: "Old", date: longAgo, at: thisWeek)
        #expect(!fresh.needsLookup(title: "Old", date: longAgo, now: thisWeek.addingTimeInterval(7 * 3600)))
    }
}
