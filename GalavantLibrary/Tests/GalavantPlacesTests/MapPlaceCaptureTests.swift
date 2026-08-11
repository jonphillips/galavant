import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

@MainActor
@Suite struct MapPlaceCaptureTests {
  @Test func createsAPrefilledDraftForANewPlace() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
    } operation: {
      let draft = await MapPlaceCapture().draft(for: Self.place)

      #expect(draft.id != nil)
      expectNoDifference(draft.name, "Noma")
      expectNoDifference(draft.kind, .food)
      expectNoDifference(draft.regionName, "Copenhagen")
      expectNoDifference(draft.address, "Refshalevej 96, Copenhagen")
      expectNoDifference(draft.phone, "+45 32 96 32 97")
      expectNoDifference(draft.url, "https://noma.dk")
      expectNoDifference(draft.mapItemIdentifier, "map-item-noma")
    }
  }

  @Test func reusesAnExistingMapsIdentityAndFillsItsBlanks() async throws {
    let existingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        try Idea.insert {
          Idea.Draft(
            id: existingID,
            name: "Our Noma note",
            notes: "Book the garden table.",
            mapItemIdentifier: "map-item-noma"
          )
        }
        .execute(db)
      }

      let draft = await MapPlaceCapture().draft(for: Self.place)

      expectNoDifference(draft.id, existingID)
      expectNoDifference(draft.name, "Our Noma note")
      expectNoDifference(draft.notes, "Book the garden table.")
      expectNoDifference(draft.kind, .food)
      expectNoDifference(draft.address, "Refshalevej 96, Copenhagen")
      expectNoDifference(draft.url, "https://noma.dk")
    }
  }

  @Test func neverDeduplicatesAPlaceWithoutAMapsIdentity() async throws {
    let existingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.defaultDatabase) var database
      try await database.write { db in
        try Idea.insert {
          Idea.Draft(id: existingID, name: "Noma", latitude: 55.6839, longitude: 12.6109)
        }
        .execute(db)
      }

      var place = Self.place
      place.mapItemIdentifier = nil
      let draft = await MapPlaceCapture().draft(for: place)

      #expect(draft.id != nil)
      #expect(draft.id != existingID)
    }
  }

  private static let place = Place(
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
}
