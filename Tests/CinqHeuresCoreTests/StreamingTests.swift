import Foundation
import Testing
@testable import CinqHeuresCore

@Suite struct StreamingTests {
    /// The shape of `movie/<id>/watch/providers`, cut down.
    private func page(_ json: String) throws -> TMDBClient.ProvidersPage {
        try JSONDecoder().decode(TMDBClient.ProvidersPage.self, from: Data(json.utf8))
    }

    @Test func subscriptionsComeFirstWithoutTheirAdVariants() throws {
        let providers = try page("""
        {"id":1,"results":{"BE":{"link":"https://www.themoviedb.org/movie/1/watch?locale=BE",
          "flatrate":[{"provider_name":"Netflix Standard with Ads","logo_path":"/a.jpg","display_priority":3},
                      {"provider_name":"Netflix","logo_path":"/n.jpg","display_priority":1},
                      {"provider_name":"Amazon Prime Video","logo_path":"/p.jpg","display_priority":2},
                      {"provider_name":"Cinemax Amazon Channel","logo_path":"/c.jpg","display_priority":4}],
          "rent":[{"provider_name":"Apple TV","logo_path":"/t.jpg","display_priority":1}]},
          "FR":{"flatrate":[{"provider_name":"Canal+","display_priority":1}]}}}
        """)
        let found = try #require(TMDBClient.streaming(in: providers, region: "BE"))
        #expect(found.kind == .subscription)
        #expect(found.services.map(\.name) == ["Netflix", "Amazon Prime Video"])
        #expect(found.services.first?.logoURL == URL(string: "https://image.tmdb.org/t/p/w92/n.jpg"))
        #expect(found.link == URL(string: "https://www.themoviedb.org/movie/1/watch?locale=BE"))
        #expect(TMDBClient.streaming(in: providers, region: "NL") == nil)
    }

    @Test func freeThenRentWhenNoSubscription() throws {
        let free = try page(#"{"results":{"BE":{"ads":[{"provider_name":"Auvio","display_priority":5}],"rent":[{"provider_name":"Apple TV"}]}}}"#)
        #expect(TMDBClient.streaming(in: free, region: "BE")?.kind == .free)
        let rent = try page(#"{"results":{"BE":{"rent":[{"provider_name":"Apple TV"},{"provider_name":"Google Play Movies"}]}}}"#)
        #expect(TMDBClient.streaming(in: rent, region: "BE").map { [$0.kind.rawValue] + $0.services.map(\.name) } == ["rent", "Apple TV", "Google Play Movies"])
    }

    @Test func aFilmIsTheOneOfThatTitleFromAboutThatYear() {
        let results = TMDBClient.SearchPage(results: [
            .init(id: 10, title: "Peacock", original_title: "Peacock", release_date: "2008-01-01", overview: nil, poster_path: nil, popularity: 9),
            .init(id: 11, title: "Peacock", original_title: "Pfau - Bin ich echt?", release_date: "2024-09-01", overview: nil, poster_path: nil, popularity: 3),
        ])
        #expect(TMDBClient.movieID(in: results, titled: "Pfau - Bin ich echt?", year: 2025) == 11)
        #expect(TMDBClient.movieID(in: results, titled: "Peacock", year: 2025) == 11)
        #expect(TMDBClient.movieID(in: results, titled: "Peacock", year: 2008) == 10)
        #expect(TMDBClient.movieID(in: results, titled: "Le Paon", year: 2025) == nil)
    }
}
