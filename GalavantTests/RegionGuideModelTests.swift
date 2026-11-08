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
  func openingAnotherIdeaReplacesTheDossierAndCloseClearsIt() {
    let firstIdea = Idea(id: UUID(-10), name: "First")
    let nextIdea = Idea(id: UUID(-11), name: "Next")
    let model = RegionGuideModel()

    model.ideaTapped(firstIdea)
    model.ideaTapped(nextIdea)
    #expect(model.dossierID == nextIdea.id)

    model.closeDossier()
    #expect(model.dossierID == nil)
  }

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
    model.task(scope: RegionGuideScope(region: region, category: .dining))
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

  @Test @MainActor
  func guideEntryUsesTheSingleActiveTripSubregion() async throws {
    let trip = Trip(id: UUID(), name: "Paris and Lyon")
    let paris = MapRegion(
      id: UUID(), name: "Paris", centerLatitude: 48, centerLongitude: 2,
      latitudeDelta: 1, longitudeDelta: 1
    )
    let lyon = MapRegion(
      id: UUID(), name: "Lyon", centerLatitude: 45, centerLongitude: 4,
      latitudeDelta: 1, longitudeDelta: 1
    )
    try await database.write { db in
      try Trip.insert { Trip.Draft(trip) }.execute(db)
      try MapRegion.insert { MapRegion.Draft(paris) }.execute(db)
      try MapRegion.insert { MapRegion.Draft(lyon) }.execute(db)
      try TripRegion.insert { TripRegion.Draft(TripRegion(id: UUID(), tripID: trip.id, regionID: paris.id)) }.execute(db)
      try TripRegion.insert { TripRegion.Draft(TripRegion(id: UUID(), tripID: trip.id, regionID: lyon.id)) }.execute(db)
    }

    let model = IdeasListModel()
    try await model.$trips.load()
    try await model.$tripRegions.load()
    try await model.$regions.load()
    model.activeTripID = trip.id
    model.selectedSubregionIDs = [lyon.id]
    model.$lastGuideRegionIDString.withLock { $0 = paris.id.uuidString }
    model.guideButtonTapped()
    if case let .guide(scope) = model.destination {
      #expect(scope.region == lyon)
    } else {
      Issue.record("Expected the guide destination")
    }

    model.selectedSubregionIDs = []
    model.guideButtonTapped()
    if case let .guide(scope) = model.destination {
      #expect(scope.region == paris)
    } else {
      Issue.record("Expected the guide destination")
    }
  }
}
