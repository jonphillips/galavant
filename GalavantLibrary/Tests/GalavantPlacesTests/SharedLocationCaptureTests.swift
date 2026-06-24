import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantCapture
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

/// Capturing a place shared *as a location* — Apple Maps map item or vCard (ADR-0020)
/// — by seeding the existing parse→match→save pipeline from a `SharedLocation`.
@MainActor
@Suite struct SharedLocationCaptureTests {
  @Test("SharedLocation synthesizes a structured ParsedPage")
  func parsedPageSynthesis() {
    let location = SharedLocation(
      name: "Restaurant Es:senz",
      latitude: 47.78, longitude: 12.45,
      street: "Kirchplatz 1", locality: "Grassau", region: "Bavaria",
      phone: "+49 123", websiteURL: URL(string: "https://es-senz.de"),
      mapItemIdentifier: "MAPS-ID-123"
    )
    let page = location.parsedPage(capturedAt: Date(timeIntervalSince1970: 0))

    #expect(page.title == "Restaurant Es:senz")
    // A Maps name is authoritative — a confident match corroborates, never overrides.
    #expect(page.titleIsStructured)
    #expect(page.coordinate == ParsedCoordinate(latitude: 47.78, longitude: 12.45))
    #expect(page.address.street == "Kirchplatz 1")
    #expect(page.address.locality == "Grassau")
    #expect(page.phone == "+49 123")
    #expect(page.websiteURL == URL(string: "https://es-senz.de"))
  }

  @Test("An empty name yields an unstructured (nil) title")
  func parsedPageEmptyName() {
    let page = SharedLocation(name: "").parsedPage(capturedAt: Date())
    #expect(page.title == nil)
    #expect(!page.titleIsStructured)
  }

  @Test("A Maps map-item seed fills the draft and preserves its persistent identity")
  func captureFromMapItem() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      // A coordinate-bearing page resolves coordinate-first, so the matcher is never
      // consulted — and crucially carries no identifier of its own to overwrite ours.
      $0.placeMatcher = .testValue
    } operation: {
      let location = SharedLocation(
        name: "Restaurant Es:senz",
        latitude: 47.78, longitude: 12.45,
        locality: "Grassau", region: "Bavaria",
        phone: "+49 123", websiteURL: URL(string: "https://es-senz.de"),
        mapItemIdentifier: "MAPS-ID-123"
      )
      let model = CaptureModel(location: location)
      await model.prepare()

      #expect(model.phase == .ready)
      #expect(model.draft.name == "Restaurant Es:senz")
      #expect(model.draft.latitude == 47.78)
      #expect(model.draft.longitude == 12.45)
      #expect(model.draft.regionName == "Grassau")
      #expect(model.draft.phone == "+49 123")
      #expect(model.draft.url == "https://es-senz.de")
      // The shared Maps identity survives a coordinate-first match that has none.
      #expect(model.draft.mapItemIdentifier == "MAPS-ID-123")
    }
  }

  @Test("A vCard seed (no coordinate) resolves coordinate + identity from the match")
  func captureFromVCard() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { _ in
          [
            Place(
              id: UUID(), name: "Es:senz", latitude: 47.78, longitude: 12.45,
              regionName: "Grassau", kind: .food, mapItemIdentifier: "MAPS-ID-999"
            )
          ]
        }
      )
    } operation: {
      // A vCard carries name + postal address but no coordinate or Maps identity.
      let location = SharedLocation(name: "Es:senz", locality: "Grassau")
      let model = CaptureModel(location: location)
      await model.prepare()

      #expect(model.draft.latitude == 47.78)
      #expect(model.draft.longitude == 12.45)
      // The match is the only identity source for a vCard.
      #expect(model.draft.mapItemIdentifier == "MAPS-ID-999")
    }
  }
}
