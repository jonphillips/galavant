import Foundation
import GalavantCapture
import Testing

@testable import GalavantPlaces

@Suite struct PlaceMatchingTests {
  // MARK: Signal ladder

  @Test("Full page yields the whole ladder, strongest signal first")
  func fullLadder() {
    let page = ParsedPage(
      title: "Noma",
      coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109),
      address: ParsedAddress(street: "Refshalevej 96", locality: "Copenhagen")
    )
    #expect(
      PlaceMatching.ladder(for: page) == [
        .coordinates(latitude: 55.6839, longitude: 12.6109),
        .geocodeAddress("Refshalevej 96, Copenhagen"),
        .biasedTextSearch(query: "noma copenhagen"),
        .worldwideTextSearch(query: "noma copenhagen"),
      ]
    )
  }

  @Test("No coordinates or address: text search only")
  func textOnlyLadder() {
    let page = ParsedPage(title: "Tivoli Gardens")
    #expect(
      PlaceMatching.ladder(for: page) == [
        .biasedTextSearch(query: "tivoli gardens"),
        .worldwideTextSearch(query: "tivoli gardens"),
      ]
    )
  }

  @Test("A page with no usable signal yields an empty ladder")
  func emptyLadder() {
    #expect(PlaceMatching.ladder(for: ParsedPage()).isEmpty)
  }

  // MARK: Query tokenizing

  @Test("Query drops stopwords and aggregator noise, keeps name + city")
  func queryTokens() {
    let page = ParsedPage(
      title: "Reservations at The Noma",
      address: ParsedAddress(locality: "Copenhagen")
    )
    #expect(PlaceMatching.searchQuery(for: page) == "noma copenhagen")
  }

  @Test("Apostrophes stay inside words")
  func apostrophes() {
    #expect(PlaceMatching.words(in: "Joe's Café") == ["joe's", "café"])
  }

  // MARK: Scoring

  @Test("Name + street overlap scores higher than name alone")
  func scoringPrefersBothMatching() {
    let bothMatch = PlaceMatching.score(
      candidateName: "Noma",
      candidateStreet: "Refshalevej 96",
      scrapedName: "Noma",
      scrapedStreet: "Refshalevej 96"
    )
    let nameOnly = PlaceMatching.score(
      candidateName: "Noma",
      candidateStreet: "Somewhere Else 12",
      scrapedName: "Noma",
      scrapedStreet: "Refshalevej 96"
    )
    #expect(bothMatch > nameOnly)
    #expect(nameOnly > 0)
  }

  @Test("Common-word counting is case-insensitive")
  func commonWordsCaseInsensitive() {
    #expect(PlaceMatching.commonWordCount("Noma Restaurant", "noma bakery") == 1)
    #expect(PlaceMatching.commonWordCount("totally", "different") == 0)
  }
}
