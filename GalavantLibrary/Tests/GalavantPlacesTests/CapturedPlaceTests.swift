import Foundation
import GalavantCapture
import GalavantSchema
import Testing

@testable import GalavantPlaces

@Suite struct CapturedPlaceTests {
  private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

  private func nomaPage() -> ParsedPage {
    ParsedPage(
      sourceURL: URL(string: "https://www.yelp.com/biz/noma"),
      title: "Noma",
      summary: "Three-Michelin-star Nordic restaurant.",
      phone: "+45 32 96 32 97",
      websiteURL: URL(string: "https://noma.dk"),
      coordinate: ParsedCoordinate(latitude: 55.6839, longitude: 12.6109),
      address: ParsedAddress(
        street: "Refshalevej 96",
        locality: "Copenhagen",
        region: "Hovedstaden",
        postalCode: "1432",
        country: "DK"
      ),
      imageURLs: [URL(string: "https://noma.dk/hero.jpg")!],
      socialURLs: [URL(string: "https://instagram.com/nomacph")!],
      schemaTypes: ["Restaurant", "LocalBusiness"],
      openingHours: ["Tuesday,Wednesday 17:00-23:00"],
      capturedAt: Date(timeIntervalSince1970: 1_000_000)
    )
  }

  @Test("A parsed page maps onto a confirm-and-tweak idea draft")
  func mapsToDraft() {
    let captured = CapturedPlace.from(nomaPage(), id: id)
    let draft = captured.draft

    #expect(draft.id == id)
    #expect(draft.name == "Noma")
    // The page descriptor maps to `description`; `notes` is the user's own space (ADR-0026).
    #expect(draft.description == "Three-Michelin-star Nordic restaurant.")
    #expect(draft.notes == "")
    #expect(draft.kind == .food)  // Restaurant wins over generic LocalBusiness
    #expect(draft.phone == "+45 32 96 32 97")
    #expect(draft.url == "https://noma.dk")  // the place's own site
    #expect(draft.regionName == "Copenhagen")
    #expect(draft.address == "Refshalevej 96, Copenhagen, Hovedstaden, 1432, DK")
    #expect(draft.latitude == 55.6839)
    #expect(draft.longitude == 12.6109)
  }

  @Test("Carry-over signals the Idea schema doesn't hold are preserved, not dropped")
  func keepsExtras() {
    let captured = CapturedPlace.from(nomaPage(), id: id)
    #expect(captured.imageURLs == [URL(string: "https://noma.dk/hero.jpg")!])
    #expect(captured.socialURLs == [URL(string: "https://instagram.com/nomacph")!])
    #expect(captured.openingHours == ["Tuesday,Wednesday 17:00-23:00"])
    #expect(captured.websiteURL == URL(string: "https://noma.dk"))
    #expect(captured.sourceURL == URL(string: "https://www.yelp.com/biz/noma"))
    #expect(captured.capturedAt == Date(timeIntervalSince1970: 1_000_000))
  }

  @Test("A sparse page still maps without crashing; missing fields stay empty/nil")
  func sparsePage() {
    let captured = CapturedPlace.from(
      ParsedPage(title: "Mystery Spot"), id: id, travelPartyID: nil
    )
    #expect(captured.draft.name == "Mystery Spot")
    #expect(captured.draft.notes == "")
    #expect(captured.draft.kind == nil)
    #expect(captured.draft.url == "")
    #expect(captured.draft.regionName == nil)
    #expect(captured.draft.address == nil)
    #expect(captured.draft.latitude == nil)
    #expect(captured.imageURLs.isEmpty)
  }
}
