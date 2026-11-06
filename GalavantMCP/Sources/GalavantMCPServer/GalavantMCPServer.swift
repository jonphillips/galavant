import ChatAccessKit
import Foundation
import GalavantSchema
import LLMHandoffKit
import MCPServerKit

private struct StageInput: Decodable, Sendable {
  let trip: String
  let text: String
}

private struct StageResult: Encodable, Sendable {
  let staged: String
  let next: String
}

public enum GalavantMCPServer {
  public static func make(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    isDevelopment: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> MCPServer {
    MCPServer(
      name: "galavant", version: "0.1.0", instructions: RecommendationHandoffContract.chatServerInstructions,
      tools: [
        MCPTool(
          name: "stage_trip_return",
          description: "Call this instead of printing a Galavant return. Pass the trip UUID from GV-TRIP and the complete return text, including the GV-HANDOFF and GV-CONTRACT lines and candidate JSON. The options are staged for review in Galavant.",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "trip": .object(["type": .string("string")]),
              "text": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("trip"), .string("text")]),
            "additionalProperties": .bool(false),
          ]),
          annotations: .init(readOnly: false, destructive: false, openWorld: false)
        ) { input in
          guard let data = try? JSONEncoder().encode(input),
            let payload = try? JSONDecoder().decode(StageInput.self, from: data),
            let trip = UUID(uuidString: payload.trip)
          else {
            return .error("Provide a trip UUID and return text. Tap Hand off in Galavant and paste the brief here to get the trip ID.")
          }
          do {
            let validated = try StagedTripReturn.validate(payload.text)
            guard case let .candidates(_, candidates, _) = validated else {
              return .error("Trip seeds cannot be staged yet. Print the return for pasting into Galavant.")
            }
            let folder = try ChatAccessHelperFolder.existing(
              containerIdentifier: "iCloud.com.jonphillips.galavant", isDevelopment: isDevelopment, home: home
            )
            let inbox = HandoffInbox(root: folder.inboxURL, fileExtension: "gvreturn")
            _ = try inbox.stage(payload.text, slug: trip.uuidString, now: now())
            return .json(StageResult(staged: "\(candidates.count) options", next: "Review them in Galavant → Evaluate."))
          } catch {
            return .error(error.localizedDescription)
          }
        }
      ]
    )
  }
}
