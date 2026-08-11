import CustomDump
import Foundation
import GalavantSchema
import Testing

@testable import GalavantPlaces

@Suite struct PlaceIdeaTests {
  @Test func mapsEveryCapturedPlaceFieldToAnIdea() {
    let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let place = Place(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
      name: "Noma",
      latitude: 55.6839,
      longitude: 12.6109,
      regionName: "Copenhagen",
      kind: .food,
      url: "https://noma.dk",
      phone: "+45 32 96 32 97",
      address: "Refshalevej 96, Copenhagen",
      mapItemIdentifier: "map-item-noma"
    )

    expectNoDifference(
      place.idea(id: id),
      Idea(
        id: id,
        name: "Noma",
        kind: .food,
        regionName: "Copenhagen",
        address: "Refshalevej 96, Copenhagen",
        phone: "+45 32 96 32 97",
        latitude: 55.6839,
        longitude: 12.6109,
        url: "https://noma.dk",
        mapItemIdentifier: "map-item-noma"
      )
    )
  }
}
