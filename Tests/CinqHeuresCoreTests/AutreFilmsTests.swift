import Foundation
import Testing
@testable import CinqHeuresCore

/// Descriptions as 5heures.be writes them for its "Autre" specials.
@Suite struct AutreFilmsTests {
    private func names(_ description: String) -> [String] { AutreProgramme.films(in: description).map(\.title) }

    @Test func readsTheFilmListAndStopsAtTheNextSection() {
        let monaco = "Thème : Monaco Cinéma : La Main au collet (Alfred Hitchcock), Le roman d’un tricheur (Sacha Guitry) et La fille de Monaco (Anne Fontaine) Musique : 28 degrés à l’ombre (Jean-François Maurice), Il faut naitre à Monaco (Joe Dassin)"
        let films = AutreProgramme.films(in: monaco)
        #expect(films.map(\.title) == ["La Main au collet", "Le roman d’un tricheur", "La fille de Monaco"])
        #expect(films.map(\.directors) == [["Alfred Hitchcock"], ["Sacha Guitry"], ["Anne Fontaine"]])
        // Songs straight after the films, without a label: the film after "et" ends the list.
        let christmas = "Films : L’assassinat du Père Noël (Christian-Jacque), L’étrange Noël de Mister Jack (Henry Selick) et Le Père Noël est une ordure (Jean-Marie Poiré) La fille du Père Noël (Bijou), I Believe in Father Christmas (Greg Lake)"
        #expect(names(christmas) == ["L’assassinat du Père Noël", "L’étrange Noël de Mister Jack", "Le Père Noël est une ordure"])
        // A section before the films, a colon inside a title, a second section after.
        #expect(names("BD : Little Nemo (Winsor McCay) Films : Da Vinci Code (Ron Howard) et 1492 : Christophe Colomb (Ridley Scott) Livre : Max et les Maximonstres (Maurice Sendak)")
                == ["Da Vinci Code", "1492 : Christophe Colomb"])
        #expect(names("Rudy et Hugues te donnent rendez-vous sur la plage, coco !") == [])
    }

    @Test func remarksCommasAndSeveralDirectors() {
        let triporteur = AutreProgramme.films(in: "Films : Le Triporteur (Jacques Pinoteau) d'après le roman de René Fallet et René La Canne (Francis Girod) Musiques : Nous (Hervé Vilard)")
        #expect(triporteur.map(\.title) == ["Le Triporteur", "René La Canne"])
        let liege = AutreProgramme.films(in: "Films : Simenon au cinéma, Mon père ce Héros (Gérard Lauzier) et Je pense à vous (Luc et Jean-Pierre Dardenne)")
        #expect(liege.first?.alternatives == ["Mon père ce Héros"])
        #expect(liege.last?.directors == ["Luc", "Jean-Pierre Dardenne"])
        #expect(names("Films : Blow up (Michelangelo Antonioni) et Cousin, cousine (Jean-Charles Tacchella)") == ["Blow up", "Cousin, cousine"])
        #expect(names("Films : Wedding Bells (Godley &amp;amp; Creme) et Un mariage (Robert Altman)") == ["Wedding Bells", "Un mariage"])
    }

    @Test func directorsMatchDespiteTypos() {
        #expect(TMDBClient.sameDirector(["Michael Radofrd"], ["Michael Radford"]))
        #expect(TMDBClient.sameDirector(["Luc", "Jean-Pierre Dardenne"], ["Luc Dardenne", "Jean-Pierre Dardenne"]))
        #expect(!TMDBClient.sameDirector(["Lewis Carroll"], ["Tim Burton"]))
        #expect(!TMDBClient.sameDirector(["Paul King"], ["Paul Greengrass"]))
    }

    @Test func theProgrammeShowsFoundFilmsAndDropsTheRest() {
        let date = EpisodeDates.short.date(from: "26/08/2022")!
        let episode = Episode(id: 994, series: .autre, date: date,
                              summary: "Films : Le Triporteur (Jacques Pinoteau) d'après le roman de René Fallet et René La Canne (Francis Girod)",
                              audioURL: URL(string: "https://example.org/a.mp3")!, segments: [])
        var library = FilmLibrary()
        // Before any lookup: both, untimed, under their own names.
        #expect(episode.withNamedFilms(from: library).segments.map(\.title) == ["Le Triporteur", "René La Canne"])
        #expect(episode.withNamedFilms(from: library).segments.allSatisfy { $0.start == nil && $0.id < 0 })
        library.record(FilmInfo(tmdbID: 1, title: "Le Triporteur", originalTitle: "Le Triporteur", year: 1957, overview: "Un livreur.",
                                posterPath: "/t.jpg", director: "Jacques Pinoteau"), title: "Le Triporteur", date: date)
        library.record(nil, title: "René La Canne", date: date)
        let timed = episode.withNamedFilms(from: library)
        #expect(timed.segments.map(\.title) == ["Le Triporteur (1957)"])
        #expect(timed.segments.first?.overview == "Un livreur.")
        // Applying again changes nothing; other shows are left alone.
        #expect(timed.withNamedFilms(from: library) == timed)
        let podcast = Episode(id: 1, series: .podcast, date: date, summary: "Films : Rocky (John G. Avildsen)", audioURL: episode.audioURL, segments: [])
        #expect(podcast.withNamedFilms(from: library) == podcast)
    }
}

@Suite struct ShippedSnapshotTests {
    /// The snapshot the apps ship: current fields, every show, and the "Autre" films already matched.
    @Test func theShippedCatalogueIsCurrentAndComplete() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Snapshot")
        let catalogue = try #require(Catalogue.load(from: folder.appendingPathComponent("snapshot-catalogue.json")))
        #expect(!catalogue.needsFullDownload)
        #expect(Set(catalogue.episodes.map(\.series)) == Set(Series.allCases))
        #expect(catalogue.episodes.flatMap(\.segments).contains { $0.slug != nil })
        let films = FilmLibrary.load(from: folder.appendingPathComponent("snapshot-films.json"))
        #expect(films.entries.values.filter { $0.info != nil }.count > 300)
        var mine = FilmLibrary()
        #expect(mine.adopt(films) && !mine.adopt(films))
    }
}
