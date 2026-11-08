import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

@Suite(.serialized, .dependencies { try $0.bootstrapDatabase() })
struct RegionGuideModelTests {
  @Dependency(\.defaultDatabase) private var database

  @Test @MainActor
  func modelGuideMatchesThePackageReadModelAndDoNotDoMovesTheCard() async throws {
    let partyID = UUID()
    let region = MapRegion(
      id: UUID(), name: "Virginia", centerLatitude: 38, centerLongitude: -78,
      latitudeDelta: 8, longitudeDelta: 8, travelPartyID: partyID
    )
    let idea = Idea(
      id: UUID(), name: "Cafe", kind: .food, latitude: 38, longitude: -78,
      travelPartyID: partyID
    )
    let jon = Planner(id: UUID(), displayName: "Jon", travelPartyID: partyID)
    let wendy = Planner(id: UUID(), displayName: "Wendy", travelPartyID: partyID)
    let note = TasteNote(
      id: UUID(), travelPartyID: partyID, plannerID: jon.id, ideaID: idea.id,
      placeName: idea.name, body: "Good lunch", notedAt: Date(timeIntervalSince1970: 10)
    )
    try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID, name: "Test")) }.execute(db)
      try MapRegion.insert { MapRegion.Draft(region) }.execute(db)
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      try Planner.insert { Planner.Draft(jon) }.execute(db)
      try Planner.insert { Planner.Draft(wendy) }.execute(db)
      try TasteNote.insert { TasteNote.Draft(note) }.execute(db)
    }

    let model = RegionGuideModel()
    model.task(scope: RegionGuideScope(region: region, category: .dining), availableRegions: [region])
    try await model.$ideas.load()
    try await model.$evaluations.load()
    try await model.$interests.load()
    try await model.$planners.load()
    try await model.$notes.load()
    let expected = RegionGuide(
      region: region, category: .dining, shelf: .all, ideas: [idea], evaluations: [],
      interests: [], planners: [jon, wendy], notes: [note]
    )
    #expect(model.guide == expected)

    try await database.write { db in
      try IdeaInterest.insert {
        IdeaInterest.Draft(IdeaInterest(id: UUID(), ideaID: idea.id, plannerID: jon.id, level: .doNotDo))
      }.execute(db)
    }
    try await model.$interests.load()
    model.shelf = .notForMe
    #expect(model.guide?.counts[.notForMe] == 1)
    #expect(model.guide?.sections.flatMap(\.cards).map(\.idea.id) == [idea.id])
  }
}
