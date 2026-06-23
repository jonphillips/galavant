import Foundation

/// A tool the model may call (ADR-0017 §3) — the verb vocabulary the chat shares
/// with the App Intents work. Backend-agnostic: the Anthropic wire maps this to a
/// `tools[]` entry (`name`/`description`/`input_schema`); the on-device tier
/// ignores tools (its tool-use is limited — the richer loop is a frontier-tier
/// capability, ADR-0017 §3).
public struct ModelTool: Sendable, Equatable {
  public var name: String
  public var description: String
  /// JSON Schema for the tool's input — a `JSONValue.object` (`{"type":"object",
  /// "properties":{…},"required":[…]}`).
  public var inputSchema: JSONValue

  public init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

/// A model's request to run a tool — one `tool_use` block. The app dispatches by
/// `name`, runs the verb over `input`, and returns a `tool_result` keyed by `id`
/// (the loop in `ChatModel`).
public struct ModelToolCall: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var input: JSONValue

  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}
