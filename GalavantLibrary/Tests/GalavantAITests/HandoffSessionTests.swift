import Foundation
import GalavantAI
import Testing

struct HandoffSessionTests {
  @Test func routesAndStripsTheToken() throws {
    let id = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let routed = try HandoffRouting.route("Intro\nGV-HANDOFF: \(id.uuidString)\nReturn")

    #expect(routed.sessionID == id)
    #expect(routed.text == "Intro\nReturn")
  }

  @Test func rejectsAMissingContractMarkerLoudly() {
    let marker = HandoffContractMarker(prefix: "GV-CONTRACT", version: "v1")

    #expect(throws: HandoffContractError.missingMarker(expected: "GV-CONTRACT: v1")) {
      try marker.strippingMarker(from: "[]")
    }
  }

  @Test func decodesSessionsSavedBeforeCandidateTrackingWasAdded() throws {
    let session = HandoffSession(
      id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
      sourceType: "trip",
      sourceID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
      taskType: "candidatePlaces",
      exportedPrompt: "Prompt"
    )
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
    object.removeValue(forKey: "candidatePayload")
    object.removeValue(forKey: "candidateLinks")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(HandoffSession.self, from: legacy)
    #expect(decoded.candidatePayload == nil)
    #expect(decoded.candidateLinks.isEmpty)
  }
}
