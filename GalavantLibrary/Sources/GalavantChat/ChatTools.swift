import Dependencies
import Foundation
import LLMClientKit
import GalavantSchema
import SQLiteData

/// Runs the chat's tool calls (ADR-0017 §3). Injected into `ChatModel` so the
/// loop's dispatch is testable with a stub (the app target stays untestable —
/// `galavant-app-target-untestable`); the live executor runs the verbs over the
/// tested `GalavantSchema` core.
public protocol ChatToolExecutor: Sendable {
  /// The tools to advertise to the model this turn.
  func tools() -> [ModelTool]
  /// Run one call and return its `tool_result` text.
  func run(_ call: ModelToolCall) async -> String
}

/// The v1 chat verb vocabulary (ADR-0017 §3) — read-leaning, shared in spirit with
/// the "AI pool-stocking" App Intents work. `queryPool` answers pool-wide
/// questions; `createIdea` lands a **candidate** (ADR-0013), keeping the pull
/// decision the user's. Trip mutation (`scheduleStop`) is deferred.
public enum ChatVerb: String, Sendable, CaseIterable {
  case queryPool = "query_pool"
  case createIdea = "create_idea"

  public var tool: ModelTool {
    switch self {
    case .queryPool:
      ModelTool(
        name: rawValue,
        description: """
          Search the whole idea pool — beyond what's on screen. Use for questions \
          like "which Denmark food ideas haven't we visited?". All filters are \
          optional and combine (AND).
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "kind": [
              "type": "string",
              "description": "Idea kind, e.g. food, drink, sight, museum, beach.",
            ],
            "region": [
              "type": "string",
              "description": "Match ideas whose region name contains this text.",
            ],
            "query": [
              "type": "string",
              "description": "Free text matched against the idea name and notes.",
            ],
            "includeVisited": [
              "type": "boolean",
              "description": "Include already-visited ideas. Defaults to true.",
            ],
          ],
          "required": [],
        ]
      )
    case .createIdea:
      ModelTool(
        name: rawValue,
        description: """
          Add a new idea to the pool as a candidate. It is NOT pulled onto any \
          trip — the user still decides that. Use only when the user clearly asks \
          to add or save a place.
          """,
        inputSchema: [
          "type": "object",
          "properties": [
            "name": ["type": "string", "description": "The place or idea name."],
            "notes": ["type": "string", "description": "Optional notes."],
            "kind": [
              "type": "string",
              "description": "Optional kind, e.g. food, drink, sight, museum.",
            ],
            "region": ["type": "string", "description": "Optional region name."],
          ],
          "required": ["name"],
        ]
      )
    }
  }
}

/// The live executor: runs the v1 verbs against the database (ADR-0017 §3). Pure
/// matching delegates to `GalavantSchema` where possible; the rest is thin DB I/O.
public struct PoolToolExecutor: ChatToolExecutor {
  @Dependency(\.defaultDatabase) var database

  public init() {}

  public func tools() -> [ModelTool] {
    ChatVerb.allCases.map(\.tool)
  }

  public func run(_ call: ModelToolCall) async -> String {
    switch ChatVerb(rawValue: call.name) {
    case .queryPool: await queryPool(call.input)
    case .createIdea: await createIdea(call.input)
    case .none: "Unknown tool: \(call.name)."
    }
  }

  // MARK: - Verbs

  private func queryPool(_ input: JSONValue) async -> String {
    let kind = input.string("kind").flatMap(Self.parseKind)
    let region = input.string("region")?.lowercased()
    let query = input.string("query")?.lowercased()
    let includeVisited = input.bool("includeVisited") ?? true

    let ideas = (try? await database.read { db in
      try Idea.order(by: \.name).fetchAll(db)
    }) ?? []

    let matches = ideas.filter { idea in
      if let kind, idea.kind != kind { return false }
      if let region, !(idea.regionName?.lowercased().contains(region) ?? false) { return false }
      if !includeVisited, idea.visited { return false }
      if let query, !query.isEmpty {
        let haystack = (idea.name + " " + idea.description + " " + idea.notes).lowercased()
        if !haystack.contains(query) { return false }
      }
      return true
    }

    guard !matches.isEmpty else { return "No ideas match that query." }
    let listed = matches.prefix(40).map { "- " + ChatContext.summarize($0) }
    var result = "Found \(matches.count) idea(s):\n" + listed.joined(separator: "\n")
    if matches.count > 40 { result += "\n…and \(matches.count - 40) more." }
    return result
  }

  private func createIdea(_ input: JSONValue) async -> String {
    guard let name = input.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty
    else {
      return "Couldn't add the idea: a name is required."
    }
        // Pass only Sendable values across the write boundary; the generated
        // `Idea.Draft` is not Sendable, so build it inside the closure.
    let id = UUID()
    let notes = input.string("notes") ?? ""
    let kind = input.string("kind").flatMap(Self.parseKind)
    let region = input.string("region")
    do {
      try await database.write { db in
        _ = try Idea.save(
          Idea.Draft(
            Idea(id: id, name: name, notes: notes, kind: kind, regionName: region)
          ),
          tagNames: [], in: db)
      }
      return "Added \"\(name)\" to the pool as a candidate. You can pull it onto a trip when ready."
    } catch {
      return "Couldn't add \"\(name)\" to the pool."
    }
  }

  /// Parse a model-supplied kind string against the stable raw value first, then
  /// the human label (case-insensitive) — the model may say "food" or "Food".
  static func parseKind(_ raw: String) -> IdeaKind? {
    let lowered = raw.lowercased()
    return IdeaKind.allCases.first {
      $0.rawValue.lowercased() == lowered || $0.label.lowercased() == lowered
    }
  }
}
