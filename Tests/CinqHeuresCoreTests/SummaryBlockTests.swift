import Testing
@testable import CinqHeuresCore

@Suite struct SummaryBlockTests {
    @Test func titlesThenParagraphs() {
        let text = """
        Le drame du Heysel revisité dans Heysel 85
        Le film belge Heysel 85 revient sur la tragédie du Heysel en s'intéressant aux coulisses du drame.
        La bienveillance excessive de Soudain
        Le film franco-japonais Soudain met en scène la rencontre entre Marilou et Marie.
        """
        #expect(SummaryBlock.blocks(text) == [
            .heading("Le drame du Heysel revisité dans Heysel 85"),
            .paragraph("Le film belge Heysel 85 revient sur la tragédie du Heysel en s'intéressant aux coulisses du drame."),
            .heading("La bienveillance excessive de Soudain"),
            .paragraph("Le film franco-japonais Soudain met en scène la rencontre entre Marilou et Marie."),
        ])
    }

    @Test func markedHeadingsAndPoints() {
        let text = """
        - Critique du film Marsupilami :
        - Adaptation très décevante du classique de Franquin, à éviter pour les fans de la BD.
        - Public cible flou : officiellement pour enfants.
        - À l’opposé : À pied d’œuvre (Valérie Donzelli) :
        - Drame intimiste inspiré de l’histoire vraie de Franck Courtez.
        """
        #expect(SummaryBlock.blocks(text) == [
            .heading("Critique du film Marsupilami"),
            .item("Adaptation très décevante du classique de Franquin, à éviter pour les fans de la BD."),
            .item("Public cible flou : officiellement pour enfants."),
            .heading("À l’opposé : À pied d’œuvre (Valérie Donzelli)"),
            .item("Drame intimiste inspiré de l’histoire vraie de Franck Courtez."),
        ])
    }

    @Test func questionsThenSongs() {
        let text = """
        Quel personnage fascinant est au cœur de cette comédie autrichienne ?
        Que raconte le nouveau film de Quentin Dupieux ?

        Les découvertes musicales :
        HAIM - Headphones On
        - Eloi - Gender Bass Violence
        """
        #expect(SummaryBlock.blocks(text) == [
            .paragraph("Quel personnage fascinant est au cœur de cette comédie autrichienne ?"),
            .paragraph("Que raconte le nouveau film de Quentin Dupieux ?"),
            .heading("Les découvertes musicales"),
            .item("HAIM - Headphones On"),
            .item("Eloi - Gender Bass Violence"),
        ])
    }

    @Test func aLongLineEndingWithAColonIsNoHeading() {
        let text = """
        - Carrière et rythme de vie :
        - Marceau assume des périodes de recul (peu de tournages ces dernières années) pour se ressourcer :
        """
        #expect(SummaryBlock.blocks(text) == [
            .heading("Carrière et rythme de vie"),
            .item("Marceau assume des périodes de recul (peu de tournages ces dernières années) pour se ressourcer :"),
        ])
    }

    @Test func plainTextStaysParagraphs() {
        #expect(SummaryBlock.blocks("Une seule ligne.") == [.paragraph("Une seule ligne.")])
        #expect(SummaryBlock.blocks("Pourquoi ce film ?\nComment cette série ?") ==
                [.paragraph("Pourquoi ce film ?"), .paragraph("Comment cette série ?")])
    }
}
