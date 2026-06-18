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
      // Backfilled blanks from the re-parsed website.
      #expect(idea?.notes == "A Korean-Nordic tasting menu in Copenhagen.")
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
