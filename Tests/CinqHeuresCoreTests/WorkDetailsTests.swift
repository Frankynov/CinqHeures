import Foundation
import Testing
@testable import CinqHeuresCore

@Suite struct WorkDetailsTests {
    /// The shape of `/api/movies/<slug>`, cut down.
    private let peacock = Data("""
    {"movie":{"id":4518,"name":"Pfau - Bin ich echt?","name_fr":"Peacock","overview":" Besoin d’un petit ami cultivé ? ",
     "people":[{"name":"Albrecht Schuch","job":{"id":1,"name":"Actor"}},{"name":"Bernhard Wenger","job":{"id":4,"name":"Director"}},
               {"name":"Bernhard Wenger","job":{"id":21,"name":"Writer"}}],"critics":[]}}
    """.utf8)

    @Test func aFilmPageGivesSynopsisFrenchTitleAndDirector() {
        let details = SiteClient.details(fromMoviePage: peacock)
        #expect(details == WorkDetails(overview: "Besoin d’un petit ami cultivé ?", localTitle: "Peacock",
                                       director: "Bernhard Wenger", source: .site))
        let bare = Data(#"{"movie":{"name":"Les Pas perdus","name_fr":"Les Pas perdus","overview":"","people":[]}}"#.utf8)
        #expect(SiteClient.details(fromMoviePage: bare) == nil)
    }

    @Test func aSeriesIsTheOneOfThatNameAlreadyOnTheAir() {
        let page = TMDBClient.SeriesPage(results: [
            .init(name: "The Survivors", original_name: "The Survivors", first_air_date: "2030-01-01", overview: "Pas encore.", popularity: 90),
            .init(name: "Les Survivants", original_name: "The Survivors", first_air_date: "2025-06-06", overview: "Un drame en Tasmanie.", popularity: 20),
            .init(name: "Survivors", original_name: "Survivors", first_air_date: "2008-11-23", overview: "Une épidémie.", popularity: 50),
        ])
        let date = EpisodeDates.short.date(from: "20/06/2025")!
        #expect(TMDBClient.series(in: page, titled: "The Survivors", discussedOn: date)
                == WorkDetails(overview: "Un drame en Tasmanie.", localTitle: "Les Survivants", source: .tmdb))
        #expect(TMDBClient.series(in: page, titled: "Olympo", discussedOn: date) == nil)
    }

    @Test func keysAndLookups() throws {
        let episode = Episode(id: 1, series: .podcast, date: Date(), summary: "", audioURL: URL(string: "https://example.org/a.mp3")!, segments: [])
        let film = Segment(id: 1, title: "Peacock (2025)", kind: .movie, start: 10, verdict: nil, posterURL: nil, slug: "peacock")
        let series = Segment(id: 2, title: "The Survivors", kind: .tvShow, start: 20, verdict: nil, posterURL: nil)
        #expect(WorkDetails.key(for: Work(title: film.title, kind: .movie, mentions: [.init(episode: episode, segment: film)])) == "movie:peacock")
        #expect(WorkDetails.key(for: Work(title: series.title, kind: .tvShow, mentions: [.init(episode: episode, segment: series)])) == "tv:the survivors")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var library = WorkDetailsLibrary()
        #expect(library.needsLookup("movie:peacock", now: now))
        library.record(WorkDetails(overview: "…", source: .site), for: "movie:peacock", at: now)
        library.record(nil, for: "tv:olympo", at: now)
        #expect(!library.needsLookup("movie:peacock", now: now.addingTimeInterval(400 * 86_400)))
        #expect(!library.needsLookup("tv:olympo", now: now.addingTimeInterval(6 * 86_400)))
        #expect(library.needsLookup("tv:olympo", now: now.addingTimeInterval(8 * 86_400)))
    }

    @Test func theSiteGivesEachFilmItsSlug() throws {
        let json = Data("""
        {"podcasts":[{"id":1613,"kind":"cinq_heures","display_name":"Podcast du 27/06/2025","available_at":"2025-07-27",
          "description":"","audio_file_url":"https://example.org/a.mp3","parts":[
          {"id":8167,"display_name":"Pfau - Bin ich echt? (2025)","kind":"movie","start_second":252,"score":"","score_text":"","poster_url":null,"slug":"peacock"},
          {"id":8168,"display_name":"Olympo","kind":"tv_show","start_second":900,"score":"","score_text":"","poster_url":null,"slug":null}]}],
         "pagination":{"total_pages":1}}
        """.utf8)
        let episodes = try JSONDecoder().decode(WirePage.self, from: json).podcasts.compactMap(\.episode)
        #expect(episodes.first?.segments.map(\.slug) == ["peacock", nil])
    }
}
