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

  @Test("Seed obvious choice requires one result to cover every significant key word")
  func seedObviousChoice() {
    let exact = Place(id: UUID(), name: "Dyvig Badehotel", latitude: 0, longitude: 0)
    let partial = Place(id: UUID(), name: "Dyvig Restaurant", latitude: 0, longitude: 0)
    let other = Place(id: UUID(), name: "Dyvig Badehotel Nordborg", latitude: 0, longitude: 0)
    #expect(SeedMatching.obviousChoice(keys: ["dyvigbadehotel"], results: [exact, partial]) == exact)
    #expect(SeedMatching.obviousChoice(keys: ["dyvigbadehotel"], results: [exact, other]) == nil)
    #expect(SeedMatching.obviousChoice(keys: ["dyvigbadehotel"], results: [partial]) == nil)
    #expect(SeedMatching.obviousChoice(keys: ["ND122 2"], results: [exact]) == nil)
    let ruth = Place(id: UUID(), name: "Ruth's Hotel", latitude: 0, longitude: 0)
    #expect(SeedMatching.obviousChoice(keys: ["ruthshotel"], results: [ruth]) == ruth)
    let cafe = Place(id: UUID(), name: "Café Central", latitude: 0, longitude: 0)
    #expect(SeedMatching.obviousChoice(keys: ["cafecentral"], results: [cafe]) == cafe)
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

  @Test("Name must overlap: a street-only coincidence scores 0")
  func nameMustOverlap() {
    // The koancph.dk regression: name-only "Koan 23" vs an Apple Maps hit on
    // "23 Koa Ln, Statesville, NC". The bare numeric "23" is the only common
    // token, and numbers don't count — so the name never overlaps and the score
    // collapses to 0 rather than auto-accepting the junk pin.
    let score = PlaceMatching.score(
      candidateName: "23 Koa Ln",
      candidateStreet: "23 Koa Ln, Statesville, NC",
      scrapedName: "Koan 23",
      scrapedStreet: ""
    )
    #expect(score == 0)
  }

  @Test("Numeric and ≤2-char tokens don't count toward overlap")
  func insignificantTokensDropped() {
    // Only "main" is a significant shared token; "1", "st", "23" are dropped.
    #expect(PlaceMatching.significantCommonWordCount("1 Main St", "23 Main St") == 1)
    #expect(PlaceMatching.significantCommonWordCount("23", "23 Koa Ln") == 0)
    #expect(PlaceMatching.isSignificant("23") == false)
    #expect(PlaceMatching.isSignificant("st") == false)
    #expect(PlaceMatching.isSignificant("2024") == false)
    #expect(PlaceMatching.isSignificant("koan") == true)
  }
}
