import CoreGraphics
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantCapture
import GalavantSchema
import ImageIO
import SQLiteData
import Testing
import UniformTypeIdentifiers

@testable import GalavantPlaces

@MainActor
@Suite struct PlaceEnricherTests {
  nonisolated private static let websiteHTML = """
    <html><head>
    <meta property="og:title" content="Koan">
    <meta property="og:description" content="A Korean-Nordic tasting menu in Copenhagen.">
    <meta property="og:image" content="https://koancph.dk/exterior.jpg">
    <meta property="og:image" content="https://koancph.dk/dining-room.jpg">
    <script type="application/ld+json">{
      "@context": "https://schema.org", "@type": "Restaurant", "name": "Koan",
      "address": { "@type": "PostalAddress", "addressLocality": "Copenhagen" }
    }</script>
    </head><body></body></html>
    """

  /// A restaurant site with structured opening hours — the deterministic parser finds them.
  nonisolated private static let siteWithHoursHTML = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org", "@type": "Restaurant", "name": "Spot",
      "openingHours": "Tu-Sa 17:00-23:00"
    }</script>
    </head><body></body></html>
    """

  /// A Squarespace-shaped site (brewerybhavana.com miss): styled hours widget, no schema.org markup.
  nonisolated private static let unstructuredSiteHTML = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org", "@type": "Organization", "name": "Brewery Bhavana"
    }</script>
    </head><body>
    <div class="module--hours"><p class="hours-entry">Wed–Sun</p><p class="hours-entry">5pm–10pm</p></div>
    </body></html>
    """

  @Test("Enrich takes the second hop: backfills blanks, stores ranked images, stamps enrichedAt")
  func enrichBackfillsAndStores() async throws {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(stamp)
      $0.pageFetcher = PageFetcher { _ in Self.websiteHTML }
      $0.imageFetcher = ImageFetcher { url in Self.png(for: url) }
      // The dining room scores above the logo (which Vision would flag as utility).
      $0.imageRecommender = ImageRecommender { data in
        data == Self.png(for: URL(string: "https://koancph.dk/dining-room.jpg")!) ? 0.9 : 0.2
      }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(
            id: ideaID, name: "Koan", url: "https://koancph.dk", travelPartyID: party.id
          )
        }
        .execute(db)
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      let (idea, images) = try await database.read { db in
        try (
          Idea.find(ideaID).fetchOne(db),
          ImageAsset.images(forIdea: ideaID, in: db)
        )
      }
      // Backfilled blanks from the re-parsed website (descriptor → description, ADR-0026).
      #expect(idea?.description == "A Korean-Nordic tasting menu in Copenhagen.")
      #expect(idea?.regionName == "Copenhagen")
      #expect(idea?.kind == .food)  // schema.org Restaurant
      #expect(idea?.enrichedAt == stamp)  // stamped, so it won't run again
      // Both images stored; the higher-scored dining room is the header (over the logo).
      #expect(images.count == 2)
      #expect(images.first?.sourceURL == "https://koancph.dk/dining-room.jpg")
      #expect(images.first?.isHeader == true)
    }
  }

  @Test("Enrich runs once — a second call is a no-op (enrichedAt guard)")
  func enrichRunsOnce() async throws {
    let fetchCount = LockIsolated(0)
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.pageFetcher = PageFetcher { _ in
        fetchCount.withValue { $0 += 1 }
        return Self.websiteHTML
      }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Koan", url: "https://koancph.dk", travelPartyID: party.id)
        }
        .execute(db)
      }
      let enricher = PlaceEnricher()
      await enricher.enrichIfNeeded(ideaID: ideaID)
      await enricher.enrichIfNeeded(ideaID: ideaID)
      #expect(fetchCount.value == 1)  // second call short-circuits on enrichedAt
    }
  }

  @Test("Enrich is a no-op for an idea with no website URL")
  func enrichSkipsWhenNoURL() async throws {
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.pageFetcher = PageFetcher { _ in Issue.record("should not fetch"); return nil }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "No website", travelPartyID: party.id)
        }
        .execute(db)
      }
      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)
      let idea = try await database.read { db in try Idea.find(ideaID).fetchOne(db) }
      #expect(idea?.enrichedAt == nil)  // never stamped
    }
  }

  @Test("A failed page fetch leaves the idea unstamped for a later retry")
  func enrichLeavesRetryableOnFetchFailure() async throws {
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.pageFetcher = .testValue  // returns nil
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Koan", url: "https://koancph.dk", travelPartyID: party.id)
        }
        .execute(db)
      }
      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)
      let idea = try await database.read { db in try Idea.find(ideaID).fetchOne(db) }
      #expect(idea?.enrichedAt == nil)  // unstamped → retryable
    }
  }

  @Test("Enrich backfills hours from the place's own site via the deterministic parser")
  func enrichBackfillsStructuredHours() async throws {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(stamp)
      $0.pageFetcher = PageFetcher { _ in Self.siteWithHoursHTML }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Spot", url: "https://spot.example", travelPartyID: party.id)
        }
        .execute(db)
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == "Tu-Sa 17:00-23:00")
      #expect(idea.hoursProvenance == .official)
      #expect(idea.hoursVerifiedAt == stamp)
    }
  }

  @Test("Enrich backfills hours via LLM fallback for an unstructured-markup site")
  func enrichBackfillsHoursViaLLMFallback() async throws {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(stamp)
      $0.pageFetcher = PageFetcher { _ in Self.unstructuredSiteHTML }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
      $0.hoursExtractor = HoursExtractor { _ in "Wed–Sun 5:00 PM–10:00 PM" }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Brewery Bhavana", url: "https://brewerybhavana.com", travelPartyID: party.id)
        }
        .execute(db)
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == "Wed–Sun 5:00 PM–10:00 PM")
      #expect(idea.hoursProvenance == .official)
      #expect(idea.hoursVerifiedAt == stamp)
    }
  }

  @Test("Enrich does not overwrite existing hours (fill-blanks-only)")
  func enrichPreservesExistingHours() async throws {
    let ideaID = UUID()
    let originalHours = "Mo-Fr 10:00-18:00"
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.pageFetcher = PageFetcher { _ in Self.siteWithHoursHTML }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Spot", url: "https://spot.example", travelPartyID: party.id)
        }
        .execute(db)
        try Idea.setOpeningHours(
          ideaID: ideaID, hours: originalHours, provenance: .manual,
          verifiedAt: Date(timeIntervalSince1970: 1), in: db
        )
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == originalHours)  // not clobbered by the re-parsed site
      #expect(idea.hoursProvenance == .manual)
    }
  }

  // MARK: Render-on-miss (ADR-0024)

  /// A JS-app shell the raw GET returns: an empty container that parses to nothing.
  nonisolated private static let shellHTML = """
    <html><head></head><body><div id="root"></div></body></html>
    """

  @Test("Render-on-miss: an empty static parse escalates to the rendered DOM, which backfills")
  func enrichRendersOnEmptyStaticParse() async throws {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(stamp)
      $0.pageFetcher = PageFetcher { _ in Self.shellHTML }  // raw GET: empty shell
      $0.renderedPageFetcher = RenderedPageFetcher { _ in Self.websiteHTML }  // rendered: rich
      $0.imageFetcher = ImageFetcher { url in Self.png(for: url) }
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Koan", url: "https://koancph.dk", travelPartyID: party.id)
        }
        .execute(db)
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.description == "A Korean-Nordic tasting menu in Copenhagen.")  // from the rendered DOM
      #expect(idea.regionName == "Copenhagen")
      #expect(idea.enrichedAt == stamp)
    }
  }

  @Test("The rendered fetch is skipped when the cheap GET already parses to something usable")
  func renderedFetchSkippedOnUsableStaticParse() async throws {
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.pageFetcher = PageFetcher { _ in Self.websiteHTML }  // already usable
      $0.renderedPageFetcher = RenderedPageFetcher { _ in
        Issue.record("the heavy rendered fetch must not run when the GET parsed fine")
        return nil
      }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Koan", url: "https://koancph.dk", travelPartyID: party.id)
        }
        .execute(db)
      }
      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)
    }
  }

  // MARK: Guide-link rung (ADR-0021)

  /// A restaurant's own site that links out to its Michelin guide page in the body.
  nonisolated private static let siteLinkingToGuideHTML = """
    <html><head><meta property="og:title" content="Es Senz"></head>
    <body><p>Find us on the <a href="https://guide.michelin.com/en/madrid/restaurant/es-senz">MICHELIN Guide</a>.</p></body></html>
    """

  /// The Michelin guide detail page — its award text yields ★★★.
  nonisolated private static let michelinGuideHTML = """
    <html><head><script type="application/ld+json">{
      "@context": "https://schema.org", "@type": "Restaurant", "name": "Es Senz",
      "award": "Three MICHELIN Stars"
    }</script></head>
    <body><p>Three MICHELIN Stars · MICHELIN Guide 2024</p></body></html>
    """

  @Test("Enrich follows a recognized guide link and records its rating (ADR-0021)")
  func enrichFollowsGuideLink() async throws {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let ideaID = UUID()
    let fetched = LockIsolated<[String]>([])
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(stamp)
      $0.pageFetcher = PageFetcher { url in
        fetched.withValue { $0.append(url.absoluteString) }
        return url.host()?.contains("michelin") == true
          ? Self.michelinGuideHTML : Self.siteLinkingToGuideHTML
      }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Es Senz", url: "https://es-senz.com", travelPartyID: party.id)
        }
        .execute(db)
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      let evals = try await database.read { db in try IdeaEvaluation.all.fetchAll(db) }
      #expect(fetched.value.contains("https://guide.michelin.com/en/madrid/restaurant/es-senz"))
      let michelin = try #require(evals.first { $0.sourceName == "Michelin Guide" })
      #expect(michelin.nativeValueText == "3 stars")
      #expect(michelin.confidence == .official)
    }
  }

  @Test("The guide hop is idempotent: a rating the idea already carries isn't duplicated")
  func enrichGuideHopIsIdempotent() async throws {
    let ideaID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.pageFetcher = PageFetcher { url in
        url.host()?.contains("michelin") == true ? Self.michelinGuideHTML : Self.siteLinkingToGuideHTML
      }
      $0.imageFetcher = .testValue
      $0.imageRecommender = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(id: ideaID, name: "Es Senz", url: "https://es-senz.com", travelPartyID: party.id)
        }
        .execute(db)
        // The idea already has the ★★★ (recorded with different casing, to exercise the
        // case-insensitive de-dup identity shared across the parser, merge, and record).
        try IdeaEvaluation.record(
          ParsedEvaluation(
            sourceName: "michelin guide", kind: .stars, valueText: "3 STARS", display: "★★★"),
          ideaID: ideaID, travelPartyID: party.id, confidence: .official,
          asOf: Date(timeIntervalSince1970: 1), in: db
        )
      }

      await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)

      // The hop follows the link and re-detects ★★★, but the (source, kind, value)
      // identity matches the existing row case-insensitively, so nothing is doubled.
      let count = try await database.read { db in try IdeaEvaluation.all.fetchCount(db) }
      #expect(count == 1)
    }
  }

  // A distinct solid-color PNG per URL so the fixture recommender can tell them apart.
  nonisolated private static func png(for url: URL) -> Data {
    let hash = abs(url.absoluteString.hashValue)
    let red = Double(hash % 255) / 255
    let context = CGContext(
      data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: red, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = context.makeImage()!
    let buffer = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    _ = CGImageDestinationFinalize(destination)
    return buffer as Data
  }
}
