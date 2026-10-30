import CloudSyncKit
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct SyncFailureDisplayRowsTests {
  @Dependency(\.defaultDatabase) var database

  @Test
  func namesAndGroupsIdeaAndTripRowsWithoutExposingIdentifiers() {
    let ideaID = UUID().uuidString
    let tripID = UUID().uuidString
    let photo1ID = UUID().uuidString
    let photo2ID = UUID().uuidString
    let stayID = UUID().uuidString
    let report = SyncFailureReport(notUploaded: [
      NotUploadedRecordGroup(recordType: "ideas", count: 1, primaryKeys: [ideaID]),
      NotUploadedRecordGroup(recordType: "trips", count: 1, primaryKeys: [tripID]),
      NotUploadedRecordGroup(recordType: "imageAssets", count: 2, primaryKeys: [photo1ID, photo2ID]),
      NotUploadedRecordGroup(recordType: "tripStays", count: 1, primaryKeys: [stayID]),
    ], notAppliedCount: 0)
    let names: [SyncFailureRecordKey: SyncFailureDisplayName] = [
      .init(recordType: "ideas", primaryKey: ideaID): .idea("Tivoli Gardens"),
      .init(recordType: "trips", primaryKey: tripID): .trip("Denmark"),
      .init(recordType: "imageAssets", primaryKey: photo1ID): .idea("Tivoli Gardens"),
      .init(recordType: "imageAssets", primaryKey: photo2ID): .idea("Tivoli Gardens"),
      .init(recordType: "tripStays", primaryKey: stayID): .trip("Denmark"),
    ]

    let rows = SyncFailureDisplayRows.build(from: report, names: names)

    expectNoDifference(rows.map(\.title), [
      "Tivoli Gardens", "Denmark", "Photo for Tivoli Gardens", "Stay in Denmark"
    ])
    #expect(rows.contains { $0.title == "Tivoli Gardens" && $0.primaryKeys == [ideaID] })
    #expect(rows.contains { $0.title == "Denmark" && $0.primaryKeys == [tripID] })
    #expect(rows.contains {
      $0.title == "Photo for Tivoli Gardens" && Set($0.primaryKeys) == Set([photo1ID, photo2ID])
    })
    #expect(rows.contains { $0.title == "Stay in Denmark" && $0.primaryKeys == [stayID] })
    let identifiers = [ideaID, tripID, photo1ID, photo2ID, stayID]
    #expect(rows.allSatisfy { row in identifiers.allSatisfy { !row.title.contains($0) } })
  }

  @Test
  func namesReadsCurrentParentColumnsFromTheMigratedDatabase() async throws {
    let ideaID = UUID()
    let tripID = UUID()
    let interestID = UUID()
    let stayID = UUID()
    let orphanStopID = UUID()
    let missingIdeaID = UUID()
    let ideaName = "Tivoli Gardens"
    let tripName = "Denmark"

    try await database.write { db in
      try Idea.insert { Idea.Draft(Idea(id: ideaID, name: ideaName)) }.execute(db)
      try Trip.insert { Trip.Draft(Trip(id: tripID, name: tripName)) }.execute(db)
      try IdeaInterest.insert {
        IdeaInterest.Draft(IdeaInterest(id: interestID, ideaID: ideaID, plannerID: UUID()))
      }.execute(db)
      try TripStay.insert { TripStay.Draft(TripStay(id: stayID, tripID: tripID, ideaID: nil)) }.execute(db)
      try TripIdea.insert {
        TripIdea.Draft(TripIdea(id: orphanStopID, tripID: tripID, ideaID: missingIdeaID))
      }.execute(db)
    }

    let report = SyncFailureReport(notUploaded: [
      NotUploadedRecordGroup(recordType: "ideaInterests", count: 1, primaryKeys: [interestID.uuidString]),
      NotUploadedRecordGroup(recordType: "tripStays", count: 1, primaryKeys: [stayID.uuidString]),
      NotUploadedRecordGroup(recordType: "tripIdeas", count: 1, primaryKeys: [orphanStopID.uuidString]),
    ], notAppliedCount: 0)
    let rows = try await database.read { db in
      let names = try SyncFailureDisplayRows.names(from: report, in: db)
      return SyncFailureDisplayRows.build(from: report, names: names)
    }

    expectNoDifference(rows.map(\.title), [
      "Interest for \(ideaName)", "Stay in \(tripName)", "1 row"
    ])
    #expect(rows.contains { $0.recordType == "tripIdeas" && $0.title == "1 row" })

    let additionalRelationshipTables = [
      "ideaTags", "imageAssets", "ideaEvaluations", "tripRegions", "tripDocuments",
      "tripDayRegions", "tripDayTimeZones", "tripDayNotes", "tripAlternativeGroups",
    ]
    let schemaProbe = SyncFailureReport(
      notUploaded: additionalRelationshipTables.map { table in
        NotUploadedRecordGroup(recordType: table, count: 1, primaryKeys: [UUID().uuidString])
      },
      notAppliedCount: 0
    )
    let unresolvedNames = try await database.read { db in
      try SyncFailureDisplayRows.names(from: schemaProbe, in: db)
    }
    #expect(unresolvedNames.isEmpty)
  }

  @Test
  func missingParentAndUnknownTableFallBackToReadableCounts() {
    let report = SyncFailureReport(notUploaded: [
      NotUploadedRecordGroup(recordType: "ideaInterests", count: 2, primaryKeys: ["interest-id"]),
      NotUploadedRecordGroup(recordType: "futureRecords", count: 3, primaryKeys: ["future-id"]),
    ], notAppliedCount: 0)

    let rows = SyncFailureDisplayRows.build(from: report, names: [:])

    #expect(rows.contains { $0.title == "1 row" && $0.detail == "Idea Interests" })
    #expect(rows.contains { $0.title == "1 more row" && $0.detail == "Idea Interests not listed" })
    #expect(rows.contains { $0.title == "1 row" && $0.detail == "Future Records" })
    #expect(rows.allSatisfy { !$0.title.contains("interest-id") && !$0.title.contains("future-id") })
  }
}
