import Foundation
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

  @Test func recognizesSeed() throws {
    guard case .seed = try StagedTripReturn.validate("{\"places\":[{\"name\":\"Museum\"}]}") else {
      Issue.record("Expected seed")
      return
    }
  }
}
