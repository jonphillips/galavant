import ChatAccessKit
import Foundation
import GalavantAI
import GalavantSchema
import Testing

struct StagedTripReturnTests {
  @Test(arguments: [
    "[{\"name\":\"Museum\"}]",
    "{\"candidates\":[{\"name\":\"Museum\"}]}",
    "```json\n[{\"name\":\"Museum\"}]\n```",
    "[{“name”:“Museum”}]",
  ])
  func candidates(text: String) throws {
    guard case let .candidates(token, candidates, _) = try StagedTripReturn.validate(text) else {
      Issue.record("Expected candidates")
      return
    }
    #expect(token == nil)
    #expect(candidates.count == 1)
    #expect(candidates[0].name == "Museum")
  }

  @Test func routesTokenAndIgnoresTripLine() throws {
    let token = UUID()
    let text = "GV-TRIP: \(UUID())\nGV-HANDOFF: \(token)\nGV-CONTRACT: v2\n[{\"name\":\"Museum\"}]"
    guard case let .candidates(found, _, _) = try StagedTripReturn.validate(text) else {
      Issue.record("Expected candidates")
      return
    }
    #expect(found == token)
  }

  @Test func rejectsEmptyAndNewerContract() {
    #expect(throws: (any Error).self) { try StagedTripReturn.validate("[]") }
    #expect(throws: (any Error).self) { try StagedTripReturn.validate("[{\"why\":\"Good\"}]") }
    #expect(throws: (any Error).self) {
      try StagedTripReturn.validate("GV-CONTRACT: v99\n[{\"name\":\"Museum\"}]")
    }
  }

  @Test func olderMarkerIsAcceptedAndMalformedTokenFails() throws {
    guard case .candidates = try StagedTripReturn.validate("GV-CONTRACT: v1\n[{\"name\":\"Museum\"}]") else {
      Issue.record("Expected candidates")
      return
    }
    #expect(throws: (any Error).self) {
      try StagedTripReturn.validate("GV-HANDOFF: invalid\n[{\"name\":\"Museum\"}]")
    }
  }

  @Test func recognizesSeed() throws {
    guard case .seed = try StagedTripReturn.validate("{\"places\":[{\"name\":\"Museum\"}]}") else {
      Issue.record("Expected seed")
      return
    }
  }

  @Test func serverInstructionsContainTheFullProjectContract() {
    let instructions = RecommendationHandoffContract.chatServerInstructions
    #expect(String(instructions.prefix(512)).contains("stage_trip_return"))
    #expect(instructions.contains(RecommendationHandoffContract.projectInstructions))
  }

  @Test func rowsNameTheTripWhileDownloadingAndKeepEachFile() throws {
    let trip = Trip(id: UUID(), name: "Denmark")
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = HandoffInbox(root: root, fileExtension: "gvreturn")
    let first = try inbox.stage("[{\"name\":\"Museum\"}]", slug: trip.id.uuidString, now: Date(timeIntervalSince1970: 100))
    let second = try inbox.stage("[{\"name\":\"Cafe\"}]", slug: trip.id.uuidString, now: Date(timeIntervalSince1970: 200))
    let snapshots = [
      ChatInboxSnapshot(url: first.url, name: first.url.lastPathComponent, isCurrent: false),
      ChatInboxSnapshot(url: second.url, name: second.url.lastPathComponent, isCurrent: true),
    ]
    let validated = try StagedTripReturn.validate("[{\"name\":\"Cafe\"}]")
    let rows = StagedTripReturnRow.rows(from: snapshots, trips: [trip], cache: [second.url: .validated(validated)])
    #expect(rows.count == 2)
    #expect(rows.first?.url == second.url)
    #expect(rows.last?.destination == .candidates(trip, count: 0))
    #expect(rows.last?.downloadState == .downloading)
    let unknown = StagedTripReturnRow.rows(from: snapshots, trips: [], cache: [:])
    #expect(unknown.first?.destination == .unknownTrip(trip.id))
  }

}
