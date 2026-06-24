import Foundation
import Testing

@testable import GalavantCapture

/// The automated guide-link rung's capture-side pieces (ADR-0021): `PageParser` now
/// surfaces outbound links, `GuideLinkRecognizer` picks the guide-detail ones worth a
/// second hop, and `ParsedPage.fillingBlanks(from:)` folds a followed page back in.
@Suite struct GuideLinkTests {
  // MARK: Link extraction (ADR-0021 §1)

  @Test("PageParser collects outbound http(s) anchors, resolved + de-duped, junk/self excluded")
  func collectsLinks() {
    let html = """
      <html><body>
      <a href="https://guide.michelin.com/en/madrid/restaurant/es-senz">Michelin</a>
      <a href="/about">Relative</a>
      <a href="mailto:hi@es-senz.com">Mail</a>
      <a href="tel:+3491">Phone</a>
      <a href="javascript:void(0)">JS</a>
      <a href="#section">Same-page</a>
      <a href="https://es-senz.com/">Self</a>
      <a href="https://es-senz.com">Self, no trailing slash</a>
      <a href="https://guide.michelin.com/en/madrid/restaurant/es-senz#menu">Dup w/ fragment</a>
      </body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://es-senz.com/"))
    #expect(
      page.links == [
        URL(string: "https://guide.michelin.com/en/madrid/restaurant/es-senz")!,
        URL(string: "https://es-senz.com/about")!,
      ])
  }

  // MARK: Guide-link recognition (ADR-0021 §2)

  private func page(linking urls: [String]) -> ParsedPage {
    ParsedPage(sourceURL: URL(string: "https://es-senz.com/"), links: urls.compactMap(URL.init(string:)))
  }

  @Test("Michelin restaurant-detail link is recognized, named to its evaluation source")
  func michelinDetail() {
    let url = "https://guide.michelin.com/en/comunidad-de-madrid/madrid/restaurant/es-senz"
    #expect(
      GuideLinkRecognizer.recognize(in: page(linking: [url]))
        == [RecognizedGuideLink(url: URL(string: url)!, guide: "Michelin Guide")])
  }

  @Test("A single-word slug after the Michelin marker is still a detail page (no hyphen needed)")
  func michelinSingleWordSlug() {
    let url = "https://guide.michelin.com/en/spain/madrid/restaurant/disfrutar"
    #expect(GuideLinkRecognizer.recognize(in: page(linking: [url])).first?.guide == "Michelin Guide")
  }

  @Test("Guide home / locale / listing / marker-only pages are not followed")
  func rejectsNonDetail() {
    let links = [
      "https://guide.michelin.com/en",  // depth 1, no detail
      "https://guide.michelin.com/en/es/madrid/restaurants",  // section index (plural)
      "https://guide.michelin.com/en/restaurant",  // marker is the last segment, no slug after
    ]
    #expect(GuideLinkRecognizer.recognize(in: page(linking: links)).isEmpty)
  }

  @Test("A guide we know only by host needs depth and a non-section final segment")
  func genericGuideShape() {
    let detail = "https://www.theworlds50best.com/the-list/1-50/the-ledbury"
    #expect(
      GuideLinkRecognizer.recognize(in: page(linking: [detail])).first?.guide == "World's 50 Best")

    // A single-word place slug (no hyphen) still qualifies — the hyphen test used to drop it.
    let singleWord = "https://www.theworlds50best.com/the-list/1-50/noma"
    #expect(
      GuideLinkRecognizer.recognize(in: page(linking: [singleWord])).first?.guide == "World's 50 Best")

    // A shallow city index — no marker and too shallow (depth 2).
    let cityIndex = "https://www.theworlds50best.com/spain/madrid"
    #expect(GuideLinkRecognizer.recognize(in: page(linking: [cityIndex])).isEmpty)
  }

  @Test("Links to non-guide hosts are ignored")
  func ignoresNonGuides() {
    let link = "https://www.tripadvisor.com/Restaurant_Review-es-senz"
    #expect(GuideLinkRecognizer.recognize(in: page(linking: [link])).isEmpty)
  }

  // MARK: Fill-blanks merge (ADR-0021 §3)

  @Test("fillingBlanks fills only blanks, preserves identity, and de-dups merged evaluations")
  func fillBlanksMerge() {
    let stars = ParsedEvaluation(
      sourceName: "Michelin Guide", kind: .stars, valueText: "3 stars", display: "★★★")
    let base = ParsedPage(
      sourceURL: URL(string: "https://es-senz.com/"),
      title: "Es Senz", phone: "+34 91", evaluations: [stars])
    let guide = ParsedPage(
      sourceURL: URL(string: "https://guide.michelin.com/en/madrid/restaurant/es-senz"),
      title: "Es Senz — MICHELIN Guide", email: "info@es-senz.com",
      address: ParsedAddress(locality: "Madrid"),
      evaluations: [
        stars,  // duplicate — dropped
        ParsedEvaluation(
          sourceName: "Michelin Guide", kind: .badge, valueText: "Green Star", display: "Green Star"),
      ])

    let merged = base.fillingBlanks(from: guide)
    #expect(merged.title == "Es Senz")  // not clobbered
    #expect(merged.phone == "+34 91")  // kept
    #expect(merged.email == "info@es-senz.com")  // filled
    #expect(merged.address.locality == "Madrid")  // filled
    #expect(merged.sourceURL == base.sourceURL)  // identity is the base's, not the supplement's
    #expect(merged.evaluations.count == 2)  // duplicate ★★★ dropped, Green Star added
  }
}
