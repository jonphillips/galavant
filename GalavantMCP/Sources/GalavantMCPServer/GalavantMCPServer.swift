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
    now: @escaping @Sendable () -> Date = { Date() },
    exportMaterializer: ChatAccessExportReader.Materializer? = nil,
    materializationDeadline: Duration = .seconds(60)
  ) -> MCPServer {
    let exportStore = GalavantExportStore(home: home, isDevelopment: isDevelopment, now: now,
      materialize: exportMaterializer, deadline: materializationDeadline)
    let readTools = ChatAccessReadTools.make(home: home, isDevelopment: isDevelopment, now: now,
      exportMaterializer: exportMaterializer, materializationDeadline: materializationDeadline, store: exportStore)
    return MCPServer(
      name: "galavant", version: "0.1.0", instructions: RecommendationHandoffContract.chatServerInstructions,
      tools: [
        MCPTool(
          name: "stage_trip_return",
          description: "Call this instead of printing a Galavant return. The trip ID comes from GV-TRIP or list_trips. A chat with no brief has no GV-HANDOFF token and omits that line. Pass the complete return text. For a seed, include a line containing only GV-SEED before the JSON object. For candidate places, send one JSON array. The return is staged for review in Galavant.",
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
            return .error("Provide a trip UUID and return text. If this chat has no trip ID yet, call list_trips. You can also tap Hand off in Galavant and paste the brief here.")
          }
          do {
            let validated = try StagedTripReturn.validate(payload.text)
            let token: UUID?
            switch validated {
            case let .candidates(value, _, _), let .seed(value, _): token = value
            }
            if token == nil {
              // Missing or stale exports are advisory; only a successful read may reject.
              if let export = try? await exportStore.load(), !export.value.trips.contains(where: { $0.id == trip }) {
                return .error("That trip ID isn't in the latest Galavant export. Call list_trips and use one of its IDs.")
              }
            }
            let folder = try ChatAccessHelperFolder.existing(
              containerIdentifier: "iCloud.com.jonphillips.galavant", isDevelopment: isDevelopment, home: home
            )
            let inbox = HandoffInbox(root: folder.inboxURL, fileExtension: "gvreturn")
            _ = try inbox.stage(payload.text, slug: trip.uuidString, now: now())
            switch validated {
            case let .candidates(_, candidates, _):
              return .json(StageResult(staged: "\(candidates.filter { !$0.suggestedTitle.isEmpty }.count) options", next: "Review them in Galavant → Evaluate."))
            case let .seed(_, seed):
              let count = seed.placeCount
              return .json(StageResult(staged: "Trip seed · \(count) \(count == 1 ? "place" : "places")", next: "Review it in Galavant → Evaluate."))
            }
          } catch {
            return .error(error.localizedDescription)
          }
        }
      ] + readTools
    )
  }
}
