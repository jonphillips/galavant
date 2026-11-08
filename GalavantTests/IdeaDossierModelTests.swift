import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import GalavantPlaces
import SQLiteData
import Testing

@testable import Galavant

@Suite(.serialized, .dependencies { try $0.bootstrapDatabase() })
struct IdeaDossierModelTests {
  @Dependency(\.defaultDatabase) private var database

  @Test @MainActor
  func dossierFetchesOnlyTheSelectedIdeasTasteNotes() async throws {
    let partyID = UUID()
    let ideaID = UUID()
    let otherIdeaID = UUID()
    try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID, name: "Test")) }.execute(db)
      for id in [ideaID, otherIdeaID] {
        try Idea.insert { Idea.Draft(Idea(id: id, travelPartyID: partyID)) }.execute(db)
      }
      for (targetID, count) in [(ideaID, 3), (otherIdeaID, 2)] {
        for index in 0..<count {
          try TasteNote.insert {
            TasteNote.Draft(TasteNote(
              id: UUID(), travelPartyID: partyID, ideaID: targetID, placeName: "Place",
              body: "Note \(index)", notedAt: Date(timeIntervalSince1970: Double(index))))
          }.execute(db)
        }
      }
    }

    let model = IdeaDossierModel(ideaID: ideaID)
    try await model.$notes.load()
    #expect(model.notes.count == 3)
    #expect(model.dossier?.notes.count == 3)
  }

  @Test @MainActor
  func setMyInterestWritesForTheCurrentPlanner() async throws {
    let partyID = UUID()
    let plannerID = UUID()
    let ideaID = UUID()
    try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID, name: "Test")) }.execute(db)
      try Planner.insert { Planner.Draft(Planner(id: plannerID, displayName: "Jon", travelPartyID: partyID)) }.execute(db)
      try Idea.insert { Idea.Draft(Idea(id: ideaID, travelPartyID: partyID)) }.execute(db)
    }

    let model = IdeaDossierModel(ideaID: ideaID)
    model.$currentPlannerIDString.withLock { $0 = plannerID.uuidString }
    try await model.$ideas.load()
    try await model.$planners.load()
    try await model.$interests.load()
    model.setMyInterest(.mustDo)
    try await model.$interests.load()
    #expect(model.interests.count == 1)
    #expect(model.dossier?.interests.first?.level == .mustDo)
  }

  @Test @MainActor
  func editButtonTappedCreatesTheIdeaFormDraft() async throws {
    let partyID = UUID()
    let ideaID = UUID()
    try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID, name: "Test")) }.execute(db)
      try Idea.insert { Idea.Draft(Idea(id: ideaID, name: "Cafe", travelPartyID: partyID)) }.execute(db)
    }

    let model = IdeaDossierModel(ideaID: ideaID)
    try await model.$ideas.load()
    model.editButtonTapped()
    if case let .edit(presentation) = model.destination {
      #expect(presentation.draft.id == ideaID)
      #expect(presentation.draft.name == "Cafe")
    } else {
      Issue.record("Expected an edit destination")
    }
  }

  @Test @MainActor
  func headerUsesDisplayBytes() async throws {
    let partyID = UUID()
    let ideaID = UUID()
    let display = Data([1, 2, 3])
    let thumbnail = Data([4, 5])
    try await database.write { db in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: partyID, name: "Test")) }.execute(db)
      try Idea.insert { Idea.Draft(Idea(id: ideaID, travelPartyID: partyID)) }.execute(db)
      try ImageAsset.insert {
        ImageAsset.Draft(ImageAsset(
          id: UUID(), ideaID: ideaID, display: display, thumbnail: thumbnail, sortRank: 0, isHeader: true))
      }.execute(db)
    }
    let model = IdeaDossierModel(ideaID: ideaID)
    try await model.$headerRows.load()
    #expect(model.headerImage == display)
    #expect(model.headerImage != thumbnail)
  }

  @Test @MainActor
  func ideaTapOpensDossierWhileMapPlaceStillOpensForm() async throws {
    let model = IdeasListModel()
    let idea = Idea(id: UUID(), name: "Saved")
    model.ideaTapped(idea)
    if case let .dossier(id) = model.destination {
      #expect(id == idea.id)
    } else {
      Issue.record("Expected a dossier destination")
    }

    await withDependencies { $0.uuid = .incrementing } operation: {
      await model.mapPlaceTapped(Place(id: UUID(), name: "New", latitude: 1, longitude: 2))
    }
    if case let .form(presentation) = model.destination {
      #expect(presentation.draft.name == "New")
    } else {
      Issue.record("Expected a form destination")
    }
  }
}
