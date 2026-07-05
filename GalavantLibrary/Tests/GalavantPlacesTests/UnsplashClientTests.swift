import Foundation
import Testing

@testable import GalavantPlaces

/// The Unsplash search decode (ADR-0032). The live path hits the wire; here we drive
/// `parse` over captured response shapes so the tolerant decode is the tested surface
/// (no network), mirroring `PlaceDiscoveryTests`.
@Suite struct UnsplashClientTests {
  /// A trimmed but faithful `/search/photos` body: two well-formed results.
  private static let cleanBody = """
    {
      "total": 2,
      "results": [
        {
          "id": "abc123",
          "color": "#26140c",
          "urls": {
            "regular": "https://images.unsplash.com/photo-1?w=1080",
            "thumb": "https://images.unsplash.com/photo-1?w=200"
          },
          "links": { "download_location": "https://api.unsplash.com/photos/abc123/download" },
          "user": { "name": "Ada Lovelace", "username": "ada" }
        },
        {
          "id": "def456",
          "color": "#0c1a26",
          "urls": {
            "regular": "https://images.unsplash.com/photo-2?w=1080",
            "thumb": "https://images.unsplash.com/photo-2?w=200"
          },
          "links": { "download_location": "https://api.unsplash.com/photos/def456/download" },
          "user": { "name": "Grace Hopper", "username": "grace" }
        }
      ]
    }
    """

  @Test("parses a clean search body into photos")
  func parsesCleanBody() {
    let photos = UnsplashClient.parse(Data(Self.cleanBody.utf8))
    #expect(photos.count == 2)
    let first = photos.first
    #expect(first?.id == "abc123")
    #expect(first?.regularURL == "https://images.unsplash.com/photo-1?w=1080")
    #expect(first?.thumbURL == "https://images.unsplash.com/photo-1?w=200")
    #expect(first?.color == "#26140c")
    #expect(first?.photographerName == "Ada Lovelace")
    #expect(first?.photographerUsername == "ada")
    #expect(first?.downloadLocation == "https://api.unsplash.com/photos/abc123/download")
  }

  @Test("an element missing required fields drops; the rest survive")
  func dropsIncomplete() {
    let body = """
      { "results": [
        { "id": "ok", "urls": { "regular": "r", "thumb": "t" },
          "links": { "download_location": "d" }, "user": { "name": "N", "username": "u" } },
        { "id": "no-urls", "links": { "download_location": "d" } },
        { "urls": { "regular": "r", "thumb": "t" }, "links": { "download_location": "d" } }
      ] }
      """
    let photos = UnsplashClient.parse(Data(body.utf8))
    #expect(photos.map(\.id) == ["ok"])
  }

  @Test("a missing user degrades to empty attribution, not a dropped photo")
  func toleratesMissingUser() {
    let body = """
      { "results": [
        { "id": "x", "urls": { "regular": "r", "thumb": "t" },
          "links": { "download_location": "d" } }
      ] }
      """
    let photos = UnsplashClient.parse(Data(body.utf8))
    #expect(photos.count == 1)
    #expect(photos.first?.photographerName == "")
    #expect(photos.first?.photographerUsername == "")
  }

  @Test("non-JSON / empty body degrades to empty, never crashes")
  func degradesToEmpty() {
    #expect(UnsplashClient.parse(Data("not json".utf8)).isEmpty)
    #expect(UnsplashClient.parse(Data()).isEmpty)
    #expect(UnsplashClient.parse(Data(#"{"results": []}"#.utf8)).isEmpty)
  }

  @Test("the test value does no network and returns nothing")
  func testValueIsInert() async throws {
    let photos = try await UnsplashClient.testValue(query: "copenhagen")
    #expect(photos.isEmpty)
  }
}
