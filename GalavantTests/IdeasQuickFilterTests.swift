import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

@Suite(.serialized, .dependencies { try $0.bootstrapDatabase() })
struct IdeasQuickFilterTests {
  @Dependency(\.defaultDatabase) private var database

  @Test @MainActor
  func scheduleFiltersIncludeDayScheduledAndDoneAndAllClears() async throws {
    let tripID = id("10000000-0000-0000-0000-000000000001")
    let dayScheduledID = id("10000000-0000-0000-0000-000000000002")
    let doneID = id("10000000-0000-0000-0000-000000000003")
    let noDayID = id("10000000-0000-0000-0000-000000000004")
    let shortlistedID = id("10000000-0000-0000-0000-000000000005")
    let consideringID = id("10000000-0000-0000-0000-000000000006")
    let notPulledID = id("10000000-0000-0000-0000-000000000007")

    try await database.write { db in
      try Trip.insert { Trip.Draft(Trip(id: tripID, name: "Denmark")) }.execute(db)
      for (ideaID, name) in [
        (dayScheduledID, "Day scheduled"), (doneID, "Done"), (noDayID, "No day"),
        (shortlistedID, "Shortlisted"), (consideringID, "Considering"), (notPulledID, "Not pulled"),
      ] {
        try Idea.insert { Idea.Draft(Idea(id: ideaID, name: name)) }.execute(db)
      }
      for entry in [
        TripIdea(id: id("20000000-0000-0000-0000-000000000001"), tripID: tripID,
          ideaID: dayScheduledID, status: .scheduled, dayNumber: 1),
        TripIdea(id: id("20000000-0000-0000-0000-000000000002"), tripID: tripID,
          ideaID: doneID, status: .done),
        TripIdea(id: id("20000000-0000-0000-0000-000000000003"), tripID: tripID,
          ideaID: noDayID, status: .scheduled),
        TripIdea(id: id("20000000-0000-0000-0000-000000000004"), tripID: tripID,
          ideaID: shortlistedID, status: .shortlisted),
        TripIdea(id: id("20000000-0000-0000-0000-000000000005"), tripID: tripID,
          ideaID: consideringID, status: .considering),
      ] {
        try TripIdea.insert { TripIdea.Draft(entry) }.execute(db)
      }
    }

    let model = IdeasListModel()
    try await model.$ideas.load()
    try await model.$tripIdeas.load()
    model.activeTripID = tripID

    model.scheduleFilter = .scheduled
    #expect(Set(model.filteredIdeas.map(\.id)) == [dayScheduledID, doneID])

    model.scheduleFilter = .notScheduled
    #expect(
      Set(model.filteredIdeas.map(\.id)) == [noDayID, shortlistedID, consideringID, notPulledID]
    )

    model.selectCapsule(nil)
    #expect(model.scheduleFilter == nil)
  }

  @Test @MainActor
  func deletedAndConvergedTagsUseOnlyLiveSelections() async throws {
    let deletedID = id("30000000-0000-0000-0000-000000000001")
    try await database.write { db in
      try Tag.insert { Tag.Draft(Tag(id: deletedID, name: "Temporary")) }.execute(db)
    }

    let deletedModel = IdeasListModel()
    try await deletedModel.$tags.load()
    deletedModel.selectedTagIDs = [deletedID]
    try await database.write { db in try Tag.delete([deletedID], in: db) }
    try await deletedModel.$tags.load()
    #expect(!deletedModel.isFiltering)
    #expect(deletedModel.filterSummary.isEmpty)

    let survivorID = id("30000000-0000-0000-0000-000000000002")
    let loserID = id("30000000-0000-0000-0000-000000000003")
    try await database.write { db in
      try Tag.insert { Tag.Draft(Tag(id: survivorID, name: "Michelin")) }.execute(db)
      try Tag.insert { Tag.Draft(Tag(id: loserID, name: " michelin ")) }.execute(db)
    }
    let convergedModel = IdeasListModel()
    try await convergedModel.$tags.load()
    convergedModel.toggleTag(loserID)
    #expect(convergedModel.selectedTagIDs == [survivorID])
    try await database.write { db in _ = try Tag.convergeDuplicates(in: db) }
    try await convergedModel.$tags.load()
    #expect(convergedModel.effectiveSelectedTagIDs == [survivorID])
  }

  private func id(_ value: String) -> UUID { UUID(uuidString: value)! }
}
