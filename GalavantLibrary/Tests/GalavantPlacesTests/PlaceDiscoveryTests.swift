import Dependencies
import Foundation
import LLMClientKit
import Testing

@testable import GalavantPlaces

/// Web-search-grounded discovery (ADR-0018, M6e slice 0). The live path runs a
/// frontier `complete` with `web_search`; here we drive it with a stub `ModelClient`
/// so the request assembly + tolerant JSON parse are the tested surface (no network).
@Suite struct PlaceDiscoveryTests {
  @Test("parses a clean JSON array of candidates")
  func parsesArray() {
    let json = """
      [{"name":"Noma","kind":"restaurant","locality":"Copenhagen","region":"Denmark",
        "note":"Tasting menu.","sourceURL":"https://noma.dk"}]
      """
    let candidates = PlaceDiscoveryClient.parse(json)
    #expect(candidates.count == 1)
    #expect(candidates.first?.name == "Noma")
    #expect(candidates.first?.kind == "restaurant")
    #expect(candidates.first?.locality == "Copenhagen")
    #expect(candidates.first?.sourceURL == "https://noma.dk")
  }

  @Test("a chatty model that wraps the array in prose still parses")
  func parsesChattyWrapped() {
    let reply = "Here are the places I found:\n[{\"name\":\"Alléno Paris\"}]\nHope that helps."
    let candidates = PlaceDiscoveryClient.parse(reply)
    #expect(candidates.map(\.name) == ["Alléno Paris"])
  }

  @Test("malformed elements and blank names drop; the rest survive")
  func dropsMalformed() {
    let json = """
      [{"name":"Keep"},{"kind":"restaurant"},{"name":"   "},{"name":"AlsoKeep","note":"ok"}]
      """
    let candidates = PlaceDiscoveryClient.parse(json)
    #expect(candidates.map(\.name) == ["Keep", "AlsoKeep"])
  }

  @Test("non-array / non-JSON output degrades to empty, never crashes")
  func degradesToEmpty() {
    #expect(PlaceDiscoveryClient.parse("no json here").isEmpty)
    #expect(PlaceDiscoveryClient.parse("{\"name\":\"object not array\"}").isEmpty)
    #expect(PlaceDiscoveryClient.parse("").isEmpty)
  }

  @Test("the live path sends a frontier web_search request and parses the model's array")
  func livePathDrivesModel() async throws {
    try await withDependencies {
      $0.modelClient = StubModelClient { request in
        // The discovery call must be frontier-tier with web_search enabled.
        #expect(request.tier == .frontier(.anthropic))
        #expect(request.webSearchMaxUses != nil)
        #expect(request.messages.last?.text.contains("the Loire") == true)
        return ModelResponse(text: #"[{"name":"La Maison","locality":"Tours"}]"#)
      }
    } operation: {
      let candidates = try await PlaceDiscoveryClient.liveValue(
        query: "2-3 star Michelin", region: "the Loire"
      )
      #expect(candidates.map(\.name) == ["La Maison"])
      #expect(candidates.first?.locality == "Tours")
    }
  }
}
