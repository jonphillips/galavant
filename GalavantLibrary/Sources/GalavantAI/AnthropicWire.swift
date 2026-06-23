import Foundation

/// Pure encode/decode for the Anthropic Messages API wire shape, factored out of
/// `AnthropicModelClient` so request assembly and SSE parsing are unit-testable
/// with no network (ADR-0014 §2 / the package-home pattern). Verified against the
/// `claude-api` skill: `POST /v1/messages`, `x-api-key`,
/// `anthropic-version: 2023-06-01`; default model `claude-opus-4-8`, which is
/// adaptive-thinking-only — **no** `temperature`/`top_p`/`budget_tokens`
/// (they 400), so none are sent.
///
/// Snake-case wire keys (`max_tokens`, `input_schema`, `tool_use_id`, `is_error`,
/// `stop_reason`) are spelled out with explicit `CodingKeys` rather than a global
/// `keyEncodingStrategy`: the strategy would also rewrite the *nested* keys inside
/// a tool's JSON-Schema and a `tool_use`'s arbitrary input (ADR-0017 §3), which
/// must pass through verbatim.
enum AnthropicWire {
  /// Default model — `claude-opus-4-8`, 1M context (ADR-0014 §2; `claude-api`
  /// names it the default).
  static let defaultModel = "claude-opus-4-8"

  static let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
  static let version = "2023-06-01"

  // MARK: Request

  /// The JSON body for a request. `stream` toggles SSE.
  static func requestData(for request: ModelRequest, model: String, stream: Bool) throws -> Data {
    // Custom verb tools (ADR-0017) plus Anthropic's server-side web_search tool
    // when discovery asks for it (ADR-0018). Both ride one heterogeneous `tools`
    // array on the wire; a missing array is omitted entirely.
    var tools = request.tools.map(WireToolEntry.custom)
    if let maxUses = request.webSearchMaxUses {
      tools.append(.webSearch(maxUses: maxUses))
    }
    let body = RequestBody(
      model: model,
      maxTokens: request.maxTokens,
      system: request.system,
      stream: stream,
      messages: request.messages.map(WireMessage.init),
      tools: tools.isEmpty ? nil : tools
    )
    // No key strategy: explicit CodingKeys carry snake_case; nested tool
    // schema/input keys must not be rewritten.
    return try JSONEncoder().encode(body)
  }

  private struct RequestBody: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var stream: Bool
    var messages: [WireMessage]
    var tools: [WireToolEntry]?

    enum CodingKeys: String, CodingKey {
      case model, system, stream, messages, tools
      case maxTokens = "max_tokens"
    }
  }

  /// One entry in the `tools` array — either a custom verb tool or the server-side
  /// `web_search` tool (a different wire shape: a versioned `type` + `max_uses`,
  /// no `input_schema`). `web_search_20260209` is the current version (`claude-api`
  /// skill); it runs server-side and adds result pre-filtering for free.
  private enum WireToolEntry: Encodable {
    case custom(ModelTool)
    case webSearch(maxUses: Int?)

    enum CodingKeys: String, CodingKey {
      case type, name, description
      case inputSchema = "input_schema"
      case maxUses = "max_uses"
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case let .custom(tool):
        try container.encode(tool.name, forKey: .name)
        try container.encode(tool.description, forKey: .description)
        try container.encode(tool.inputSchema, forKey: .inputSchema)
      case let .webSearch(maxUses):
        try container.encode("web_search_20260209", forKey: .type)
        try container.encode("web_search", forKey: .name)
        try container.encodeIfPresent(maxUses, forKey: .maxUses)
      }
    }
  }

  /// Encodes a `ModelMessage` as `{role, content}`. A lone text block serializes
  /// as a plain string (the simple, common case); anything with tool blocks
  /// serializes as a typed content-block array.
  private struct WireMessage: Encodable {
    let message: ModelMessage
    init(_ message: ModelMessage) { self.message = message }

    enum CodingKeys: String, CodingKey { case role, content }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(message.role.rawValue, forKey: .role)
      if message.content.count == 1, case let .text(text) = message.content[0] {
        try container.encode(text, forKey: .content)
      } else {
        try container.encode(message.content.map(WireBlock.init), forKey: .content)
      }
    }
  }

  private struct WireBlock: Encodable {
    let content: ModelMessage.Content
    init(_ content: ModelMessage.Content) { self.content = content }

    enum CodingKeys: String, CodingKey {
      case type, text, id, name, input, content
      case toolUseID = "tool_use_id"
      case isError = "is_error"
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch content {
      case let .text(text):
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
      case let .toolUse(call):
        try container.encode("tool_use", forKey: .type)
        try container.encode(call.id, forKey: .id)
        try container.encode(call.name, forKey: .name)
        try container.encode(call.input, forKey: .input)
      case let .toolResult(toolUseID, text, isError):
        try container.encode("tool_result", forKey: .type)
        try container.encode(toolUseID, forKey: .toolUseID)
        try container.encode(text, forKey: .content)
        try container.encode(isError, forKey: .isError)
      }
    }
  }

  // MARK: Non-streaming response

  /// Decode a full (non-stream) response into a `ModelResponse`: concatenated text
  /// blocks plus any `tool_use` blocks as `ModelToolCall`s (ADR-0017 §3). Throws
  /// `.malformedResponse` if the body doesn't decode. Server-executed blocks
  /// (`server_tool_use` / `web_search_tool_result` from the web_search tool,
  /// ADR-0018) carry no `tool_use`/`text` we act on, so they fall through the
  /// `compactMap`s and the final answer text is still captured.
  static func response(from data: Data) throws -> ModelResponse {
    guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
      throw ModelClientError.malformedResponse
    }
    let text = body.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    let toolCalls: [ModelToolCall] = body.content.compactMap { block in
      guard block.type == "tool_use", let id = block.id, let name = block.name else {
        return nil
      }
      return ModelToolCall(id: id, name: name, input: block.input ?? .object([:]))
    }
    return ModelResponse(text: text, toolCalls: toolCalls, stopReason: body.stopReason)
  }

  /// Decode an API error body (`{"error": {"message": "..."}}`) into its message,
  /// best-effort, for surfacing in `ModelClientError.http`.
  static func errorMessage(from data: Data) -> String? {
    struct ErrorEnvelope: Decodable {
      struct APIError: Decodable { var message: String? }
      var error: APIError?
    }
    return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
  }

  private struct ResponseBody: Decodable {
    var content: [ContentBlock]
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
      case content
      case stopReason = "stop_reason"
    }
  }

  private struct ContentBlock: Decodable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: JSONValue?
  }

  // MARK: Streaming (SSE)

  /// What a single decoded SSE `data:` payload tells us. The chat streams the text
  /// deltas and the terminal stop reason; tool-use turns run through the
  /// non-streaming `complete` loop, so tool deltas aren't surfaced here. Everything
  /// else (`message_start`, `content_block_start`, `ping`, …) is `.other`.
  enum StreamEvent: Equatable {
    case delta(String)
    case stop(reason: String?)
    case other
  }

  /// Decode one SSE `data:` JSON payload. Returns `nil` only when the payload is
  /// not JSON we recognize at all.
  static func streamEvent(fromData data: Data) -> StreamEvent? {
    guard let frame = try? JSONDecoder().decode(StreamFrame.self, from: data) else { return nil }
    switch frame.type {
    case "content_block_delta":
      if let text = frame.delta?.text, frame.delta?.type == "text_delta" {
        return .delta(text)
      }
      return .other
    case "message_delta":
      return .stop(reason: frame.delta?.stopReason)
    default:
      return .other
    }
  }

  private struct StreamFrame: Decodable {
    var type: String
    var delta: Delta?

    struct Delta: Decodable {
      var type: String?
      var text: String?
      var stopReason: String?

      enum CodingKeys: String, CodingKey {
        case type, text
        case stopReason = "stop_reason"
      }
    }
  }
}
