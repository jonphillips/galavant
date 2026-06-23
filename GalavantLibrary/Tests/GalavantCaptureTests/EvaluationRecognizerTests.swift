import Foundation
import Testing

@testable import GalavantCapture

/// Recognizer coverage for source-aware capture (ADR-0016 §1): a Michelin guide
/// page, an Andrew Harper page, a generic schema.org `aggregateRating`, a 50 Best
/// listing, and a no-structured-data page (the LLM-fallback boundary — deterministic
/// recognizers must return nothing). Parsed through `PageParser` end-to-end so the
/// wiring into `ParsedPage.evaluations` is covered too.
@Suite struct EvaluationRecognizerTests {
  // MARK: Michelin — the headline done-when

  private static let michelinThreeStar = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org",
      "@type": "Restaurant",
      "name": "Geranium",
      "award": "Three MICHELIN Stars"
    }</script>
    </head><body>
      <h1>Geranium</h1>
      <p>Three MICHELIN Stars · MICHELIN Guide 2024</p>
    </body></html>
    """

  @Test("A Michelin three-star page yields a faithful ★★★ evaluation")
  func michelinThreeStars() {
    let page = PageParser.parse(
      html: Self.michelinThreeStar,
      sourceURL: URL(string: "https://guide.michelin.com/dk/en/restaurant/geranium")
    )
    let eval = try? #require(page.evaluations.first)
    #expect(page.evaluations.count == 1)  // JSON-LD award + host text de-duped to one
    #expect(eval?.sourceName == "Michelin Guide")
    #expect(eval?.kind == .stars)
    #expect(eval?.valueNumber == 3)
    #expect(eval?.valueMax == 3)
    #expect(eval?.display == "★★★")
    #expect(eval?.guideYear == 2024)
    #expect(eval?.sourceURL == "https://guide.michelin.com/dk/en/restaurant/geranium")
  }

  @Test("A Michelin Bib Gourmand page yields a badge, not stars")
  func michelinBibGourmand() {
    let html = """
      <html><body><h1>Restaurant</h1><p>Bib Gourmand in the MICHELIN Guide</p></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://guide.michelin.com/x"))
    let eval = try? #require(page.evaluations.first)
    #expect(eval?.kind == .badge)
    #expect(eval?.valueText == "Bib Gourmand")
    #expect(eval?.sourceName == "Michelin Guide")
  }

  // MARK: Andrew Harper — a 0–100 score

  @Test("An Andrew Harper page yields a native /100 score")
  func andrewHarperScore() {
    let html = """
      <html><body><h1>The Hotel</h1><p>Andrew Harper score: 96/100</p></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://www.andrewharper.com/hotels/the-hotel"))
    let eval = try? #require(page.evaluations.first)
    #expect(eval?.sourceName == "Andrew Harper")
    #expect(eval?.kind == .numericScore)
    #expect(eval?.valueNumber == 96)
    #expect(eval?.valueMax == 100)
    #expect(eval?.display == "96/100")
  }

  // MARK: schema.org aggregateRating — the generic path

  @Test("A schema.org aggregateRating yields a native numeric score on its own scale")
  func schemaOrgAggregateRating() {
    let html = """
      <html><head><script type="application/ld+json">{
        "@context": "https://schema.org",
        "@type": "Restaurant",
        "name": "Bistro",
        "aggregateRating": {
          "@type": "AggregateRating",
          "ratingValue": 4.5,
          "bestRating": 5,
          "author": { "@type": "Organization", "name": "Tripadvisor" }
        }
      }</script></head><body></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://example.com/bistro"))
    let eval = try? #require(page.evaluations.first)
    #expect(eval?.sourceName == "Tripadvisor")
    #expect(eval?.kind == .numericScore)
    #expect(eval?.valueNumber == 4.5)
    #expect(eval?.valueMax == 5)
    #expect(eval?.display == "4.5/5")
  }

  // MARK: World's 50 Best — a rank

  @Test("A World's 50 Best listing yields a native rank")
  func fiftyBestRank() {
    let html = """
      <html><body><h1>Restaurant</h1><p>No. 12 on The World's 50 Best Restaurants 2023</p></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://www.theworlds50best.com/list/1-50"))
    let eval = try? #require(page.evaluations.first)
    #expect(eval?.sourceName == "World's 50 Best")
    #expect(eval?.kind == .rank)
    #expect(eval?.valueNumber == 12)
    #expect(eval?.display == "No. 12")
  }

  // MARK: The LLM-fallback boundary

  @Test("A page with no structured rating yields no deterministic evaluations")
  func noStructuredDataYieldsNothing() {
    let html = """
      <html><head><title>A Lovely Place</title></head>
      <body><h1>A Lovely Place</h1><p>We serve dinner nightly.</p></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://aplace.example/"))
    #expect(page.evaluations.isEmpty)  // the bridge's on-device extractor would take over
  }

  @Test("A bare restaurant page with no host hint stays empty (no false positives)")
  func unrelatedNumbersDoNotMatch() {
    let page = PageParser.parse(
      html: Fixtures.jsonLDRestaurant, sourceURL: URL(string: "https://www.yelp.com/biz/noma")
    )
    #expect(page.evaluations.isEmpty)
  }
}
