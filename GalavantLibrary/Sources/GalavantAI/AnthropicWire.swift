import Foundation

/// Pure encode/decode for the Anthropic Messages API wire shape, factored out of
/// `AnthropicModelClient` so request assembly and SSE parsing are unit-testable
/// with no network (ADR-0014 §2 / the package-home pattern). Verified against the
/// `claude-api` skill: `POST /v1/messages`, `x-api-key`,
/// `anthropic-version: 2023-06-01`; default model `claude-opus-4-8`, which is
/// adaptive-thinking-only — **no** `temperature`/`top_p`/`budget_tokens`
/// (they 400), so none are sent.
enum AnthropicWire {
  /// Default model — `claude-opus-4-8`, 1M context (ADR-0014 §2; `claude-api`
  /// names it the default).
  static let defaultModel = "claude-opus-4-8"

  static let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
  static let version = "2023-06-01"

  // MARK: Request

  /// The JSON body for a request. `stream` toggles SSE.
  static func requestData(for request: ModelRequest, model: String, stream: Bool) throws -> Data {
    let body = RequestBody(
      model: model,
      maxTokens: request.maxTokens,
      system: request.system,
      stream: stream,
      messages: request.messages.map { Message(role: $0.role.rawValue, content: $0.text) }
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try encoder.encode(body)
  }

  private struct RequestBody: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var stream: Bool
    var messages: [Message]
  }

  private struct Message: Encodable {
    var role: String
    var content: String
  }

  // MARK: Non-streaming response

  /// Decode a full (non-stream) response into a `ModelResponse`, concatenating
  /// text blocks. Throws `.malformedResponse` if the body doesn't decode.
  static func response(from data: Data) throws -> ModelResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let body = try? decoder.decode(ResponseBody.self, from: data) else {
      throw ModelClientError.malformedResponse
    }
    let text = body.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    return ModelResponse(text: text, stopReason: body.stopReason)
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
  }

  private struct ContentBlock: Decodable {
    var type: String
    var text: String?
  }

  // MARK: Streaming (SSE)

  /// What a single decoded SSE `data:` payload tells us. The chat only needs the
  /// text deltas and the terminal stop reason; everything else (`message_start`,
  /// `content_block_start`, `ping`, …) is `.other`.
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
