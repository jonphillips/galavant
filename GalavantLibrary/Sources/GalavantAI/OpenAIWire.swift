import Foundation

/// Pure encode/decode for the OpenAI **Chat Completions** wire shape, the sibling
/// of `AnthropicWire` (ADR-0014 multi-provider amendment). Factored out so request
/// assembly and SSE parsing are unit-testable with no network. Chat Completions
/// (not the Responses API) is the stable, well-precedented surface and is all the
/// chat + plan-evaluation use cases need; OpenAI's own web-search mechanism differs
/// and is deferred (discovery-via-OpenAI is out of scope here).
///
/// OpenAI differs from Anthropic in three ways this file absorbs: the system prompt
/// is a `role:"system"` *message* (not a top-level field); tool results are
/// `role:"tool"` messages (not content blocks inside a user turn); and a tool call's
/// arguments ride as a **JSON string** (not an object).
enum OpenAIWire {
  /// Default model — a chat-optimized GPT-5 variant (verified current 2026-06;
  /// reasoning variants like `gpt-5.5` also work through this wire). Configurable;
  /// verify IDs against current OpenAI docs at build.
  static let defaultModel = "gpt-5.2-chat-latest"

  static let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

  // MARK: Request

  static func requestData(for request: ModelRequest, model: String, stream: Bool) throws -> Data {
    let body = RequestBody(
      model: model,
      messages: wireMessages(for: request),
      maxCompletionTokens: request.maxTokens,
      stream: stream,
      tools: request.tools.isEmpty ? nil : request.tools.map(WireTool.init)
    )
    // No key strategy: explicit CodingKeys carry snake_case; nested tool-schema /
    // tool-argument keys must pass through verbatim.
    return try JSONEncoder().encode(body)
  }

  /// Flatten the provider-agnostic messages into OpenAI's shape: the system prompt
  /// becomes a leading `system` message, and a user turn carrying `tool_result`
  /// blocks expands into one `tool` message per result (OpenAI has no
  /// tool-results-inside-a-user-turn form).
  private static func wireMessages(for request: ModelRequest) -> [WireMessage] {
    var messages: [WireMessage] = []
    if let system = request.system {
      messages.append(WireMessage(role: "system", content: .text(system)))
    }
    for message in request.messages {
      let toolResults = message.content.compactMap { block -> WireMessage? in
        guard case let .toolResult(toolUseID, text, _) = block else { return nil }
        return WireMessage(role: "tool", content: .text(text), toolCallID: toolUseID)
      }
      if !toolResults.isEmpty {
        messages.append(contentsOf: toolResults)
        continue
      }
      let text = message.content.compactMap { block -> String? in
        if case let .text(text) = block { return text }
        return nil
      }.joined()
      let toolCalls = message.content.compactMap { block -> WireToolCall? in
        guard case let .toolUse(call) = block else { return nil }
        return WireToolCall(call)
      }
      messages.append(
        WireMessage(
          role: message.role.rawValue,
          content: .text(text),
          toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
      )
    }
    return messages
  }

  private struct RequestBody: Encodable {
    var model: String
    var messages: [WireMessage]
    var maxCompletionTokens: Int
    var stream: Bool
    var tools: [WireTool]?

    enum CodingKeys: String, CodingKey {
      case model, messages, stream, tools
      case maxCompletionTokens = "max_completion_tokens"
    }
  }

  private struct WireMessage: Encodable {
    enum Content { case text(String) }
    var role: String
    var content: Content
    var toolCalls: [WireToolCall]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
      case role, content
      case toolCalls = "tool_calls"
      case toolCallID = "tool_call_id"
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(role, forKey: .role)
      // An assistant turn that *only* makes tool calls sends a null content; the
      // API rejects an empty string there.
      switch content {
      case let .text(text):
        if text.isEmpty, toolCalls?.isEmpty == false {
          try container.encodeNil(forKey: .content)
        } else {
          try container.encode(text, forKey: .content)
        }
      }
      try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
      try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
  }

  /// An assistant tool call on the wire: arguments are a **JSON string**, not an
  /// object (OpenAI's shape) — so the agnostic `JSONValue` input is serialized.
  private struct WireToolCall: Encodable {
    let call: ModelToolCall
    init(_ call: ModelToolCall) { self.call = call }

    enum CodingKeys: String, CodingKey { case id, type, function }
    enum FunctionKeys: String, CodingKey { case name, arguments }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(call.id, forKey: .id)
      try container.encode("function", forKey: .type)
      var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
      try function.encode(call.name, forKey: .name)
      let argumentData = (try? JSONEncoder().encode(call.input)) ?? Data("{}".utf8)
      try function.encode(String(decoding: argumentData, as: UTF8.self), forKey: .arguments)
    }
  }

  private struct WireTool: Encodable {
    let tool: ModelTool
    init(_ tool: ModelTool) { self.tool = tool }

    enum CodingKeys: String, CodingKey { case type, function }
    enum FunctionKeys: String, CodingKey { case name, description, parameters }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("function", forKey: .type)
      var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
      try function.encode(tool.name, forKey: .name)
      try function.encode(tool.description, forKey: .description)
      try function.encode(tool.inputSchema, forKey: .parameters)
    }
  }

  // MARK: Non-streaming response

  /// Decode a Chat Completions response into a `ModelResponse`: the first choice's
  /// message text plus any `tool_calls` (arguments parsed back from their JSON
  /// string). Throws `.malformedResponse` if the body doesn't decode.
  static func response(from data: Data) throws -> ModelResponse {
    guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
      let choice = body.choices.first
    else { throw ModelClientError.malformedResponse }
    let toolCalls: [ModelToolCall] = (choice.message.toolCalls ?? []).compactMap { call in
      guard let function = call.function else { return nil }
      let input = (function.arguments?.data(using: .utf8))
        .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
      return ModelToolCall(id: call.id ?? "", name: function.name ?? "", input: input)
    }
    return ModelResponse(
      text: choice.message.content ?? "", toolCalls: toolCalls, stopReason: choice.finishReason
    )
  }

  /// Decode an OpenAI error body (`{"error": {"message": "..."}}`), best-effort.
  static func errorMessage(from data: Data) -> String? {
    struct ErrorEnvelope: Decodable {
      struct APIError: Decodable { var message: String? }
      var error: APIError?
    }
    return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
  }

  private struct ResponseBody: Decodable {
    var choices: [Choice]
    struct Choice: Decodable {
      var message: Message
      var finishReason: String?
      enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
      }
    }
    struct Message: Decodable {
      var content: String?
      var toolCalls: [ToolCall]?
      enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
      }
    }
    struct ToolCall: Decodable {
      var id: String?
      var function: Function?
    }
    struct Function: Decodable {
      var name: String?
      var arguments: String?
    }
  }

  // MARK: Streaming (SSE)

  /// What a single decoded SSE `data:` payload tells us. The chat streams text
  /// deltas and the terminal finish reason; tool-call turns run through the
  /// non-streaming `complete` loop, so tool deltas aren't surfaced here.
  enum StreamEvent: Equatable {
    case delta(String)
    case stop(reason: String?)
    case other
  }

  /// The `[DONE]` sentinel OpenAI sends to close the stream (not JSON).
  static let doneSentinel = "[DONE]"

  /// Decode one SSE `data:` JSON payload. Returns `nil` when it isn't JSON we
  /// recognize (the caller already filters the `[DONE]` sentinel).
  static func streamEvent(fromData data: Data) -> StreamEvent? {
    guard let frame = try? JSONDecoder().decode(StreamFrame.self, from: data),
      let choice = frame.choices.first
    else { return nil }
    if let text = choice.delta?.content, !text.isEmpty { return .delta(text) }
    if let reason = choice.finishReason { return .stop(reason: reason) }
    return .other
  }

  private struct StreamFrame: Decodable {
    var choices: [Choice]
    struct Choice: Decodable {
      var delta: Delta?
      var finishReason: String?
      enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
      }
    }
    struct Delta: Decodable { var content: String? }
  }
}
