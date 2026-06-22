import Foundation

/// The frontier tier (ADR-0014 §2): a thin `URLSession` client against the
/// Anthropic Messages API, authenticated with the **user's own** key. Swift has
/// no official Anthropic SDK, so this is hand-rolled — `AnthropicWire` owns the
/// JSON/SSE shapes; this type owns transport. The key is injected at construction
/// (from the Keychain store), never embedded or synced (ADR-0014 §1).
///
/// The `URLSession` is injectable so tests can drive both paths against a stubbed
/// protocol without hitting the network (frontier verification proper is
/// device + real key, per the brief).
public struct AnthropicModelClient: ModelClient {
  /// Default model — `claude-opus-4-8` (ADR-0014 §2; the `claude-api` skill names
  /// it the default). Public so it can back the init's default argument.
  public static let defaultModel = AnthropicWire.defaultModel

  let apiKey: String
  let model: String
  let session: URLSession

  public init(
    apiKey: String,
    model: String = AnthropicModelClient.defaultModel,
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.model = model
    self.session = session
  }

  private func makeRequest(streaming: Bool, body: Data) -> URLRequest {
    var request = URLRequest(url: AnthropicWire.baseURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(AnthropicWire.version, forHTTPHeaderField: "anthropic-version")
    request.httpBody = body
    return request
  }

  public func complete(_ request: ModelRequest) async throws -> ModelResponse {
    let body = try AnthropicWire.requestData(for: request, model: model, stream: false)
    let (data, response) = try await session.data(for: makeRequest(streaming: false, body: body))
    try Self.checkStatus(response, data: data)
    return try AnthropicWire.response(from: data)
  }

  public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let body = try AnthropicWire.requestData(for: request, model: model, stream: true)
          let (bytes, response) = try await session.bytes(
            for: makeRequest(streaming: true, body: body)
          )
          try await Self.checkStreamStatus(response, bytes: bytes)
          for try await line in bytes.lines {
            // SSE frames are `field: value`; only `data:` payloads carry JSON.
            guard let payload = Self.sseDataPayload(line) else { continue }
            guard let event = AnthropicWire.streamEvent(fromData: Data(payload.utf8)) else {
              continue
            }
            switch event {
            case let .delta(text): continuation.yield(ModelChunk(text: text))
            case .stop, .other: break
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The `data:` payload of an SSE line, or nil for event/`ping`/blank lines.
  static func sseDataPayload(_ line: String) -> String? {
    guard line.hasPrefix("data:") else { return nil }
    return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
  }

  private static func checkStatus(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw ModelClientError.http(
        status: http.statusCode, message: AnthropicWire.errorMessage(from: data)
      )
    }
  }

  /// Status check for the streaming path — an error body must be drained from the
  /// byte stream before we can read its message.
  private static func checkStreamStatus(
    _ response: URLResponse, bytes: URLSession.AsyncBytes
  ) async throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      var data = Data()
      for try await byte in bytes { data.append(byte) }
      throw ModelClientError.http(
        status: http.statusCode, message: AnthropicWire.errorMessage(from: data)
      )
    }
  }
}
