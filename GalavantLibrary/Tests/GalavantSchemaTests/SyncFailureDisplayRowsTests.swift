import CloudSyncKit
import GalavantSchema
import Testing

struct SyncFailureDisplayRowsTests {
  @Test
  func namesAndGroupsIdeaAndTripRowsWithoutExposingIdentifiers() {
    let report = SyncFailureReport(notUploaded: [
      NotUploadedRecordGroup(recordType: "ideas", count: 1, primaryKeys: ["idea-id"]),
      NotUploadedRecordGroup(recordType: "trips", count: 1, primaryKeys: ["trip-id"]),
      NotUploadedRecordGroup(recordType: "imageAssets", count: 2, primaryKeys: ["photo-1", "photo-2"]),
      NotUploadedRecordGroup(recordType: "tripStays", count: 1, primaryKeys: ["stay-id"]),
    ], notAppliedCount: 0)
    let names: [SyncFailureRecordKey: SyncFailureDisplayName] = [
      .init(recordType: "ideas", primaryKey: "idea-id"): .idea("Tivoli Gardens"),
      .init(recordType: "trips", primaryKey: "trip-id"): .trip("Denmark"),
      .init(recordType: "imageAssets", primaryKey: "photo-1"): .idea("Tivoli Gardens"),
      .init(recordType: "imageAssets", primaryKey: "photo-2"): .idea("Tivoli Gardens"),
      .init(recordType: "tripStays", primaryKey: "stay-id"): .trip("Denmark"),
    ]

    let rows = SyncFailureDisplayRows.build(from: report, names: names)

    #expect(rows.contains { $0.title == "Tivoli Gardens" && $0.primaryKeys == ["idea-id"] })
    #expect(rows.contains { $0.title == "Denmark" && $0.primaryKeys == ["trip-id"] })
    #expect(rows.contains { $0.title == "Photo for Tivoli Gardens" && Set($0.primaryKeys) == ["photo-1", "photo-2"] })
    #expect(rows.contains { $0.title == "Stay in Denmark" && $0.primaryKeys == ["stay-id"] })
    #expect(rows.allSatisfy { !$0.title.contains("-id") && !$0.title.contains("photo-") })
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
