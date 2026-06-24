import CoreGraphics
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import ImageIO
import SQLiteData
import Testing
import UniformTypeIdentifiers

@testable import GalavantPlaces

@MainActor
@Suite struct CaptureModelTests {
  private static let restaurantHTML = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org",
      "@type": "Restaurant",
      "name": "Noma",
      "description": "Nordic tasting menu.",
      "url": "https://noma.dk",
      "geo": { "@type": "GeoCoordinates", "latitude": 55.6839, "longitude": 12.6109 }
    }</script>
    </head><body></body></html>
    """

  private static let nameOnlyHTML = """
    <html><head><meta property="og:title" content="Noma Restaurant"></head><body></body></html>
    """

  @Test("prepare parses the page and fills the editable draft")
  func prepareFillsDraft() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue  // scraped coordinates are authoritative anyway
    } operation: {
      let model = CaptureModel(
        html: Self.restaurantHTML, sourceURL: URL(string: "https://www.yelp.com/biz/noma")
      )
      await model.prepare()

      #expect(model.phase == .ready)
      #expect(model.draft.name == "Noma")
      #expect(model.draft.notes == "Nordic tasting menu.")
      #expect(model.draft.kind == .food)
      #expect(model.draft.url == "https://noma.dk")
      #expect(model.draft.latitude == 55.6839)
      #expect(model.draft.longitude == 12.6109)
      // The unconsumed second-hop target is preserved for app-side enrichment.
      #expect(model.captured?.websiteURL == URL(string: "https://noma.dk"))
    }
  }

  @Test("prepare fills a missing coordinate from the Apple Maps match")
  func prepareFillsCoordinateFromMatch() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { _ in [Place(id: UUID(), name: "Noma", latitude: 55.6839, longitude: 12.6109)] }
      )
    } operation: {
      let model = CaptureModel(html: Self.nameOnlyHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.draft.latitude == 55.6839)
      #expect(model.draft.longitude == 12.6109)
    }
  }

  @Test("prepare enriches blank fields from the Apple Maps match (kind/phone/region/link)")
  func prepareEnrichesFromMatch() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { _ in
          [
            Place(
              id: UUID(), name: "Noma", latitude: 55.6839, longitude: 12.6109,
              regionName: "Copenhagen", kind: .food, url: "https://noma.dk",
              phone: "+45 32 96 32 97", address: "Refshalevej 96, Copenhagen"
            )
          ]
        }
      )
    } operation: {
      // og:title only — no kind/phone/region/link on the page, so the match fills them.
      let model = CaptureModel(html: Self.nameOnlyHTML, sourceURL: nil)
      await model.prepare()
      // The page name is chrome (og:title), so the confident, overlapping Apple Maps
      // name wins over it (see prepareKeepsStructuredNameOverMatch for the inverse).
      #expect(model.draft.name == "Noma")
      #expect(model.draft.kind == .food)
      #expect(model.draft.phone == "+45 32 96 32 97")
      #expect(model.draft.regionName == "Copenhagen")
      #expect(model.draft.url == "https://noma.dk")
      #expect(model.draft.address == "Refshalevej 96, Copenhagen")
    }
  }

  @Test("A chrome-derived title yields to a confident, overlapping Apple Maps name")
  func prepareLetsMatchNameOverrideChromeTitle() async {
    let chromeHTML = """
      <html><head>
      <meta property="og:title" content="Forestis Dolomites | Boutique Wellness Hotel in Brixen">
      </head><body></body></html>
      """
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { _ in [Place(id: UUID(), name: "Forestis", latitude: 46.7, longitude: 11.65)] }
      )
    } operation: {
      let model = CaptureModel(html: chromeHTML, sourceURL: nil)
      await model.prepare()
      // Clipped chrome title was "Forestis Dolomites"; Apple Maps' canonical "Forestis"
      // overlaps it, so the cleaner name wins.
      #expect(model.draft.name == "Forestis")
    }
  }

  @Test("A structured page name is kept even when the match name differs")
  func prepareKeepsStructuredNameOverMatch() async {
    let structuredHTML = """
      <html><head><script type="application/ld+json">{
        "@context": "http://schema.org", "@type": "Restaurant", "name": "Noma"
      }</script></head><body></body></html>
      """
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { _ in [Place(id: UUID(), name: "Noma Bar", latitude: 55.68, longitude: 12.61)] }
      )
    } operation: {
      let model = CaptureModel(html: structuredHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.draft.name == "Noma")  // structured name is trusted; not clobbered
    }
  }

  @Test("useLocation applies a picked place but keeps the page's own name/kind")
  func useLocationPreservesEditedFields() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = PlaceMatcher(geocode: { _ in nil }, search: { _ in [] })
    } operation: {
      // koancph.dk shape: a real name from the page, no location resolved.
      let model = CaptureModel(html: Self.nameOnlyHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.draft.latitude == nil)

      model.useLocation(
        Place(
          id: UUID(), name: "Restaurant Koan", latitude: 55.6839, longitude: 12.6109,
          regionName: "Copenhagen", kind: .food, phone: "+4531676606",
          address: "Refshalevej 96, Copenhagen"
        )
      )
      #expect(model.draft.latitude == 55.6839)
      #expect(model.draft.longitude == 12.6109)
      #expect(model.draft.address == "Refshalevej 96, Copenhagen")
      #expect(model.draft.regionName == "Copenhagen")
      #expect(model.draft.phone == "+4531676606")
      // Page already supplied the name, so the picked place doesn't clobber it.
      #expect(model.draft.name == "Noma Restaurant")

      model.clearLocation()
      #expect(model.draft.latitude == nil)
      #expect(model.draft.address == nil)
    }
  }

  @Test("Trip picker lists the recent trip first and selected; save pulls onto it")
  func tripSelectorAndPull() async throws {
    let recentID = UUID()
    let otherID = UUID()
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.recentTripStore = RecentTripStore(read: { recentID }, record: { _ in })
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        // Two dated trips; chronological order is Italy (earlier) then Japan (later).
        try Trip.insert {
          Trip.Draft(
            id: otherID, name: "Italy", certaintyStage: .dated,
            startDate: Date(timeIntervalSince1970: 1_000_000), travelPartyID: party.id
          )
        }
        .execute(db)
        try Trip.insert {
          Trip.Draft(
            id: recentID, name: "Japan", certaintyStage: .dated,
            startDate: Date(timeIntervalSince1970: 2_000_000), travelPartyID: party.id
          )
        }
        .execute(db)
      }

      let model = CaptureModel(html: Self.restaurantHTML, sourceURL: nil)
      await model.prepare()
      // Japan is the recent trip, so it floats to the top and is pre-selected even
      // though Italy is chronologically first.
      #expect(model.trips.map(\.id) == [recentID, otherID])
      #expect(model.selectedTripID == recentID)

      await model.save()
      #expect(model.phase == .saved)
      let entries = try await database.read { db in try TripIdea.all.fetchAll(db) }
      #expect(entries.count == 1)
      #expect(entries.first?.tripID == recentID)
      #expect(entries.first?.ideaID == model.draft.id)
      #expect(entries.first?.status == .considering)
    }
  }

  @Test("Apple Intelligence mines a city that rescues the Apple Maps match")
  func intelligenceMinedCityResolvesMatch() async {
    // koancph.dk shape: a bare name, no city, no coordinate — today's parser can't
    // locate it. The model mines "Copenhagen" from the page, which both fills the
    // region and turns the worldwide name-only search into a findable query.
    let koanHTML = """
      <html><head><meta property="og:title" content="Koan"></head><body></body></html>
      """
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeIntelligence = PlaceIntelligence { _ in
        PlaceRefinement(locality: "Copenhagen", kind: .food)
      }
      // The map finds Koan only once the query carries the mined city.
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { query in
          query.lowercased().contains("copenhagen")
            ? [Place(id: UUID(), name: "Koan", latitude: 55.6867, longitude: 12.5700)]
            : []
        }
      )
    } operation: {
      let model = CaptureModel(html: koanHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.draft.latitude == 55.6867)  // resolved thanks to the mined city
      #expect(model.draft.regionName == "Copenhagen")  // mined locality → region
      #expect(model.draft.kind == .food)  // classified by the model
    }
  }

  @Test("the model's kind does not override a kind from structured data")
  func intelligenceKindDoesNotOverrideStructured() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.placeIntelligence = PlaceIntelligence { _ in PlaceRefinement(kind: .drink) }
    } operation: {
      // restaurantHTML carries schema.org Restaurant → .food; the model's guess loses.
      let model = CaptureModel(html: Self.restaurantHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.draft.kind == .food)
    }
  }

  @Test("save inserts the idea under the default travel party")
  func saveInsertsUnderDefaultParty() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(html: Self.restaurantHTML, sourceURL: nil)
      await model.prepare()
      await model.save()

      #expect(model.phase == .saved)
      let ideas = try await database.read { db in try Idea.all.fetchAll(db) }
      #expect(ideas.count == 1)
      let idea = try #require(ideas.first)
      #expect(idea.name == "Noma")
      #expect(idea.kind == .food)
      #expect(idea.travelPartyID != nil)

      let parties = try await database.read { db in try TravelParty.all.fetchAll(db) }
      #expect(parties.count == 1)
      #expect(idea.travelPartyID == parties.first?.id)
    }
  }

  @Test("Re-sharing the same Maps place supplements the existing idea, not a duplicate")
  func reShareDedupsOnMapIdentifier() async throws {
    // First share resolves a bare Maps hit (name + coordinate, no region/phone).
    let placeFirst = Place(
      id: UUID(), name: "Noma", latitude: 55.6839, longitude: 12.6109,
      mapItemIdentifier: "maps:noma-cph"
    )
    // Second share of the same place carries the richer detail the first lacked.
    let placeSecond = Place(
      id: UUID(), name: "Noma", latitude: 55.6839, longitude: 12.6109,
      regionName: "Copenhagen", phone: "+45 32 96 32 97",
      mapItemIdentifier: "maps:noma-cph"
    )
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.defaultDatabase) var database

      try await withDependencies {
        $0.placeMatcher = PlaceMatcher(geocode: { _ in nil }, search: { _ in [placeFirst] })
      } operation: {
        let first = CaptureModel(html: Self.nameOnlyHTML, sourceURL: nil)
        await first.prepare()
        #expect(first.draft.mapItemIdentifier == "maps:noma-cph")
        await first.save()
        #expect(first.phase == .saved)
      }

      try await withDependencies {
        $0.placeMatcher = PlaceMatcher(geocode: { _ in nil }, search: { _ in [placeSecond] })
      } operation: {
        let second = CaptureModel(html: Self.nameOnlyHTML, sourceURL: nil)
        await second.prepare()
        await second.save()
        #expect(second.phase == .saved)
      }

      // One idea, not two — the second share recognized the place and supplemented it.
      let ideas = try await database.read { db in try Idea.all.fetchAll(db) }
      #expect(ideas.count == 1)
      let idea = try #require(ideas.first)
      #expect(idea.mapItemIdentifier == "maps:noma-cph")
      // The blanks the first share left are now filled by the second.
      #expect(idea.regionName == "Copenhagen")
      #expect(idea.phone == "+45 32 96 32 97")
    }
  }

  @Test("A location with no Maps identity never auto-merges (no false dedup)")
  func nilIdentifierDoesNotMerge() async throws {
    // Scraped coordinates resolve a location but carry no Maps identity, so two such
    // captures must stay two ideas — we never guess that they're the same place.
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue  // scraped coordinates win; no identifier
    } operation: {
      @Dependency(\.defaultDatabase) var database
      for _ in 0..<2 {
        let model = CaptureModel(html: Self.restaurantHTML, sourceURL: nil)
        await model.prepare()
        #expect(model.draft.mapItemIdentifier == nil)
        await model.save()
      }
      let count = try await database.read { db in try Idea.all.fetchCount(db) }
      #expect(count == 2)
    }
  }

  private static let imageHTML = """
    <html><head>
    <meta property="og:title" content="Noma">
    <meta property="og:image" content="https://noma.dk/hero.jpg">
    </head><body></body></html>
    """

  @Test("save fetches and stores the best candidate as the idea's header image")
  func saveStoresHeaderImage() async throws {
    let pngBytes = Self.makePNG(width: 1200, height: 800)
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.imageFetcher = ImageFetcher { url in
        url.absoluteString == "https://noma.dk/hero.jpg" ? pngBytes : nil
      }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(html: Self.imageHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.captured?.imageURLs.first == URL(string: "https://noma.dk/hero.jpg"))
      await model.save()
      #expect(model.phase == .saved)

      let ideaID = try #require(model.draft.id)
      let images = try await database.read { db in
        try ImageAsset.images(forIdea: ideaID, in: db)
      }
      #expect(images.count == 1)
      let header = try #require(images.first)
      #expect(header.isHeader)
      #expect(header.sourceURL == "https://noma.dk/hero.jpg")
      #expect(!header.display.isEmpty)
      #expect(!header.thumbnail.isEmpty)
    }
  }

  @Test("A failed image fetch never blocks the save (best-effort)")
  func saveSucceedsWhenImageFetchFails() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.imageFetcher = .testValue  // returns nil
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(html: Self.imageHTML, sourceURL: nil)
      await model.prepare()
      await model.save()
      #expect(model.phase == .saved)

      let ideaID = try #require(model.draft.id)
      let images = try await database.read { db in
        try ImageAsset.images(forIdea: ideaID, in: db)
      }
      #expect(images.isEmpty)  // no image stored, but the idea saved fine
      let ideaCount = try await database.read { db in try Idea.all.fetchCount(db) }
      #expect(ideaCount == 1)
    }
  }

  /// A solid-color PNG the image processor can decode — no fixture files in the repo.
  private static func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
