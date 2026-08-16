import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct IdeasListDeleteTests {
  @Dependency(\.defaultDatabase) private var database

  @Test @MainActor
  func deleteUsesTheDisplayedRegionFilteredIdeas() async throws {
    let (regionBID, regionAIdeaID, regionBIdeaID) = try await database.write { db in
      let partyID = UUID(-1)
      let regionAID = UUID(-2)
      let regionBID = UUID(-3)
      let regionAIdeaID = UUID(-4)
      let regionBIdeaID = UUID(-5)
      // A one-degree region span and centers ten degrees apart make the two
      // fixtures disjoint while keeping each idea at its region's exact center.
      let regionSpan = 1.0
      let regionACoordinate = 0.0
      let regionBCoordinate = 10.0

      try TravelParty.insert {
        TravelParty.Draft(TravelParty(id: partyID, name: "Test party"))
      }
      .execute(db)
      try MapRegion.insert {
        MapRegion.Draft(
          MapRegion(
            id: regionAID,
            name: "Region A",
            centerLatitude: regionACoordinate,
            centerLongitude: regionACoordinate,
            latitudeDelta: regionSpan,
            longitudeDelta: regionSpan,
            travelPartyID: partyID
          )
        )
      }
      .execute(db)
      try MapRegion.insert {
        MapRegion.Draft(
          MapRegion(
            id: regionBID,
            name: "Region B",
            centerLatitude: regionBCoordinate,
            centerLongitude: regionBCoordinate,
            latitudeDelta: regionSpan,
            longitudeDelta: regionSpan,
            travelPartyID: partyID
          )
        )
      }
      .execute(db)
      try Idea.save(
        Idea.Draft(
          Idea(
            id: regionAIdeaID,
            name: "Apple",
            latitude: regionACoordinate,
            longitude: regionACoordinate,
            travelPartyID: partyID
          )
        ),
        tagNames: [],
        in: db
      )
      try Idea.save(
        Idea.Draft(
          Idea(
            id: regionBIdeaID,
            name: "Bravo",
            latitude: regionBCoordinate,
            longitude: regionBCoordinate,
            travelPartyID: partyID
          )
        ),
        tagNames: [],
        in: db
      )

      return (regionBID, regionAIdeaID, regionBIdeaID)
    }

    let model = IdeasListModel()
    try await model.$ideas.load()
    try await model.$regions.load()
    model.selectedRegionID = regionBID

    let displayedIdeas = model.filteredIdeas
    #expect(displayedIdeas.map(\.id) == [regionBIdeaID])

    model.deleteIdeas(displayedIdeas, at: IndexSet(integer: 0))

    let remainingIDs = try await database.read { db in
      try Idea.order(by: \.name).fetchAll(db).map(\.id)
    }
    #expect(remainingIDs == [regionAIdeaID])
  }
}
