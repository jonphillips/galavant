import Foundation
import Testing

@testable import GalavantCapture

@Suite struct PageParserTests {
  // MARK: JSON-LD — the priority layer

  @Test("JSON-LD restaurant page yields a fully-populated ParsedPage")
  func jsonLDRestaurant() {
    let page = PageParser.parse(
      html: Fixtures.jsonLDRestaurant,
      sourceURL: URL(string: "https://www.yelp.com/biz/noma-copenhagen")
    )

    #expect(page.title == "Noma")
    #expect(page.summary == "Three-Michelin-star Nordic restaurant.")
    #expect(page.phone == "+45 32 96 32 97")
    #expect(page.email == "book@noma.dk")
    #expect(page.coordinate == ParsedCoordinate(latitude: 55.6839, longitude: 12.6109))
    #expect(page.address.street == "Refshalevej 96")
    #expect(page.address.locality == "Copenhagen")
    #expect(page.address.region == "Hovedstaden")
    #expect(page.address.postalCode == "1432")
    #expect(page.address.country == "DK")
    #expect(page.imageURLs == [URL(string: "https://noma.dk/hero.jpg")!])
    #expect(page.socialURLs.contains(URL(string: "https://www.instagram.com/nomacph")!))
    #expect(page.schemaTypes.contains("Restaurant"))
    #expect(page.openingHours.contains("Tuesday,Wednesday 17:00-23:00"))
    #expect(!page.isEmpty)
  }

  @Test("websiteURL surfaces the business's own site, distinct from the shared page")
  func twoHopSignal() {
    let page = PageParser.parse(
      html: Fixtures.jsonLDRestaurant,
      sourceURL: URL(string: "https://www.yelp.com/biz/noma-copenhagen")
    )
    // The two-hop trigger: the place's site differs from where we captured it.
    #expect(page.websiteURL == URL(string: "https://noma.dk"))
    #expect(page.websiteURL?.host() != page.sourceURL?.host())
  }

  // MARK: OpenGraph + metatags

  @Test("OpenGraph mines coordinates, contact block, and out-votes the <title>")
  func openGraph() {
    let page = PageParser.parse(html: Fixtures.openGraph)

    #expect(page.title == "Tivoli Gardens")  // og:title beats "<title>" on the tie
    #expect(page.summary == "Historic amusement park in central Copenhagen.")
    #expect(page.coordinate == ParsedCoordinate(latitude: 55.6736, longitude: 12.5681))
    #expect(page.address.street == "Vesterbrogade 3")
    #expect(page.address.locality == "Copenhagen")
    #expect(page.phone == "+45 33 15 10 01")
    #expect(page.websiteURL == URL(string: "https://www.tivoli.dk"))
    #expect(page.imageURLs == [URL(string: "https://www.tivoli.dk/og.jpg")!])
  }

  // MARK: Value voting

  @Test("Agreement across layers out-votes a single junk title")
  func valueVotingByCorroboration() {
    // JSON-LD and microdata agree on the real name (2 votes); OpenGraph's SEO
    // title gets only 1 — corroboration wins regardless of pass order.
    let page = PageParser.parse(html: Fixtures.votingConflict)
    #expect(page.title == "Real Name")
  }

  // MARK: Microdata

  @Test("Microdata-only page (no JSON-LD/OG) still extracts the place")
  func microdataOnly() {
    let page = PageParser.parse(html: Fixtures.microdataHotel)

    #expect(page.title == "Hotel Danmark")
    #expect(page.phone == "+45 11 22 33 44")
    #expect(page.address.street == "Vester Voldgade 89")
    #expect(page.address.locality == "Copenhagen")
    #expect(page.websiteURL == URL(string: "https://hoteldanmark.dk"))
    #expect(page.schemaTypes.contains("Hotel"))
  }

  // MARK: Image hygiene

  @Test("Junk images are dropped and relative images resolve against the source")
  func imageFiltering() {
    let page = PageParser.parse(
      html: Fixtures.mixedImages,
      sourceURL: URL(string: "https://example.com/place/noma")
    )
    #expect(page.imageURLs == [URL(string: "https://example.com/photos/main.jpg")!])
  }

  // MARK: Fallbacks

  @Test("A barren page yields an empty ParsedPage the caller can fall back from")
  func emptyPage() {
    let page = PageParser.parse(html: "<html><body><p>nothing here</p></body></html>")
    #expect(page.isEmpty)
  }

  @Test("Malformed JSON-LD is skipped, not fatal; other layers still parse")
  func malformedJSONLDIsTolerated() {
    let page = PageParser.parse(html: Fixtures.brokenJSONLDWithOG)
    #expect(page.title == "Still Works")  // came from OpenGraph
  }

  @Test("capturedAt is the injected timestamp, not wall-clock")
  func capturedAtInjected() {
    let when = Date(timeIntervalSince1970: 1_000_000)
    let page = PageParser.parse(html: Fixtures.openGraph, capturedAt: when)
    #expect(page.capturedAt == when)
  }
}
