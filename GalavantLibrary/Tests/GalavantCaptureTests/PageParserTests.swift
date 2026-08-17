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

  @Test("a text excerpt is extracted, stripped of boilerplate and bounded")
  func textExcerptStripsBoilerplate() {
    let html = """
      <html><head><title>Alouette</title></head><body>
      <nav>Home Menu Reservations Contact</nav>
      <main><p>Alouette is a rooftop restaurant in Chicago serving French cuisine.</p></main>
      <footer>Copyright 2026</footer>
      <script>console.log("tracking")</script>
      </body></html>
      """
    let excerpt = PageParser.parse(html: html).textExcerpt
    let unwrapped = try! #require(excerpt)
    #expect(unwrapped.contains("rooftop restaurant in Chicago"))
    // Boilerplate (nav/footer/script) is dropped.
    #expect(!unwrapped.contains("Reservations"))
    #expect(!unwrapped.contains("Copyright"))
    #expect(!unwrapped.contains("tracking"))
  }

  @Test("link-dense nav is stripped even without semantic tags")
  func stripsNonSemanticNav() {
    // The menu is a bare <ul><li><a> with no <nav>/<header> — the tag-only strip
    // misses it, so link-density must catch it (das-achental.com shape).
    let page = PageParser.parse(html: Fixtures.chromeHeavyFooterHours)
    let body = try! #require(page.bodyText)
    #expect(body.contains("Michelin starred restaurant"))
    #expect(!body.contains("Golf"))
    #expect(!body.contains("Wellness"))
  }

  @Test("bottom-of-page hours survive in bodyText though the summary excerpt clips them")
  func bodyTextReachesFooterHours() {
    // The hours sit in a contact block below ~1700 chars of prose: past the summary
    // lead's 1500-char cap, but present in the full (uncapped) bodyText — so the hours
    // extractor (which reads bodyText) actually sees them. The das-achental regression.
    let page = PageParser.parse(html: Fixtures.chromeHeavyFooterHours)
    let excerpt = try! #require(page.textExcerpt)
    let body = try! #require(page.bodyText)

    #expect(excerpt.count <= 1500)
    #expect(!excerpt.contains("Wednesday - Saturday"))  // clipped from the short lead
    #expect(body.contains("Wednesday - Saturday 6.30 -11 pm"))  // reaches the model
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

  @Test("JSON-LD address given as a plain string is kept (not only PostalAddress objects)")
  func jsonLDStringAddress() {
    // Squarespace's LocalBusiness/Organization blocks ship address as multi-line
    // Text, not a PostalAddress object (the restaurantalouette.dk case). It must
    // survive as a geocodable line, else the matcher does a bare-name worldwide
    // search and lands on the wrong "Alouette".
    let html = """
      <html><head>
      <script type="application/ld+json">{
        "@context": "http://schema.org",
        "@type": "LocalBusiness",
        "name": "Alouette",
        "telephone": "+4531676606",
        "address": "8 Kronprinsessegade\\nK\\u00F8benhavn, , 1306\\nDenmark"
      }</script>
      </head><body></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://restaurantalouette.dk/home"))
    #expect(page.title == "Alouette")
    #expect(page.phone == "+4531676606")
    // Newlines and the empty `, ,` segment are collapsed into one geocodable line.
    #expect(page.address.street == "8 Kronprinsessegade, København, 1306, Denmark")
    #expect(!page.address.isEmpty)
  }

  @Test("JSON-LD name outranks an echoed page-chrome title, even mirrored in microdata")
  func structuredNameBeatsChromeTitle() {
    // The real restaurantalouette.dk case: the page title "Home — Alouette" is
    // echoed across og:title, twitter:title, <title> AND a microdata
    // <meta itemprop="name"> — four votes — while the clean JSON-LD `name`
    // ("Alouette") has one. JSON-LD must outrank microdata (which here just mirrors
    // the chrome), which must outrank bare chrome, regardless of tally.
    let html = """
      <html><head>
      <title>Home &mdash; Alouette</title>
      <meta property="og:title" content="Home — Alouette">
      <meta name="twitter:title" content="Home — Alouette">
      <meta itemprop="name" content="Home — Alouette">
      <script type="application/ld+json">{
        "@context": "http://schema.org", "@type": "LocalBusiness", "name": "Alouette"
      }</script>
      </head><body></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://restaurantalouette.dk/home"))
    #expect(page.title == "Alouette")
    #expect(page.titleIsStructured)
  }

  @Test("A page-chrome title's marketing tagline after a pipe is trimmed")
  func chromeTitleTaglineTrimmed() {
    // forestis.it/en: the only JSON-LD is a BreadcrumbList ("Homepage"), not a place
    // node, so the title falls to og:title — which carries a marketing tagline after
    // a pipe. Trim it; the brand sits before the pipe.
    let html = """
      <html><head>
      <meta property="og:title" content="Forestis Dolomites | Boutique Wellness Hotel in Brixen">
      <script type="application/ld+json">{
        "@context": "http://schema.org", "@type": "BreadcrumbList",
        "itemListElement": [{ "@type": "ListItem", "position": 1,
          "item": { "@id": "https://www.forestis.it/en", "name": "Homepage" } }]
      }</script>
      </head><body></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: URL(string: "https://www.forestis.it/en"))
    #expect(page.title == "Forestis Dolomites")
    #expect(!page.titleIsStructured)  // chrome-sourced — a confident map match may override it
    #expect(page.schemaTypes.isEmpty)  // breadcrumb is not a place node
  }

  @Test("A structured name containing a pipe is left intact (only chrome is trimmed)")
  func structuredTitleNotTrimmed() {
    let html = """
      <html><head>
      <meta property="og:title" content="Page | Site">
      <script type="application/ld+json">{
        "@context": "http://schema.org", "@type": "Restaurant", "name": "Pasta | Vino"
      }</script>
      </head><body></body></html>
      """
    let page = PageParser.parse(html: html, sourceURL: nil)
    #expect(page.title == "Pasta | Vino")
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

  @Test("Lazy-load, srcset, CSS background, and noscript images are all harvested")
  func bodyImageExtraction() {
    let page = PageParser.parse(html: Fixtures.richBodyImages)
    let urls = Set(page.imageURLs.map(\.absoluteString))
    #expect(
      urls == [
        "https://place.com/og.jpg",  // structured (og:image)
        "https://place.com/style-block.jpg",  // <style> background-image
        "https://place.com/inline-bg.jpg",  // inline style background-image
        "https://place.com/lazy.jpg",  // <img data-src>
        "https://place.com/small.jpg",  // <img srcset> first candidate
        "https://place.com/picture.webp",  // <picture><source srcset>
        "https://place.com/data-bg.jpg",  // data-bg attribute
        "https://place.com/noscript.jpg",  // <noscript> fallback
      ]
    )
    // Structured og:image stays first — the single-hop extension cover (M4f).
    #expect(page.imageURLs.first?.absoluteString == "https://place.com/og.jpg")
    // Sprite/icon junk is still filtered out in the body too.
    #expect(!urls.contains("https://place.com/icon-sprite.png"))
  }

  @Test("srcset keeps commas inside URLs and selects the first candidate")
  func srcsetPreservesURLCommas() {
    let firstWixURL =
      "https://static.wixstatic.com/media/x~mv2.png/v1/fill/w_705,h_141,q_85,enc_avif/x.png"
    let secondWixURL =
      "https://static.wixstatic.com/media/x~mv2.png/v1/fill/w_1410,h_282/x.png"
    let page = PageParser.parse(
      html: """
        <html><body>
        <img srcset="\(firstWixURL) 1x,
                     \(secondWixURL) 2x">
        <img srcset="a.jpg 1x, b.jpg 2x">
        <img srcset="c.jpg, d.jpg">
        </body></html>
        """,
      sourceURL: URL(string: "https://example.com/place")
    )

    #expect(page.imageURLs.contains(URL(string: firstWixURL)!))
    #expect(!page.imageURLs.contains(URL(string: "https://static.wixstatic.com/media/x~mv2.png/v1/fill/w_705")!))
    #expect(page.imageURLs.contains(URL(string: "https://example.com/a.jpg")!))
    #expect(page.imageURLs.contains(URL(string: "https://example.com/c.jpg")!))
    #expect(!page.imageURLs.contains(URL(string: "https://example.com/b.jpg")!))
    #expect(!page.imageURLs.contains(URL(string: "https://example.com/d.jpg")!))
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
