import Foundation

/// The OpenAI frontier backend (ADR-0014 multi-provider amendment): a thin
/// `URLSession` client against the Chat Completions API, authenticated with the
/// **user's own** key (`Authorization: Bearer`). The sibling of
/// `AnthropicModelClient` — `OpenAIWire` owns the JSON/SSE shapes, this type owns
/// transport. The `URLSession` is injectable so the transport is testable without
/// the network (real-key verification is device-side).
public struct OpenAIModelClient: ModelClient {
  /// Default model — a chat-optimized GPT-5 variant; verify against current OpenAI
  /// docs at build. Public so it can back the init's default argument.
  public static let defaultModel = OpenAIWire.defaultModel

  let apiKey: String
  let model: String
  let session: URLSession

  public init(
    apiKey: String,
    model: String = OpenAIModelClient.defaultModel,
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.model = model
    self.session = session
  }

  private func makeRequest(body: Data) -> URLRequest {
    var request = URLRequest(url: OpenAIWire.baseURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = body
    return request
  }

  public func complete(_ request: ModelRequest) async throws -> ModelResponse {
    let body = try OpenAIWire.requestData(for: request, model: model, stream: false)
    let (data, response) = try await session.data(for: makeRequest(body: body))
    try Self.checkStatus(response, data: data)
    return try OpenAIWire.response(from: data)
  }

  public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let body = try OpenAIWire.requestData(for: request, model: model, stream: true)
          let (bytes, response) = try await session.bytes(for: makeRequest(body: body))
          try await Self.checkStreamStatus(response, bytes: bytes)
          for try await line in bytes.lines {
            guard let payload = AnthropicModelClient.sseDataPayload(line) else { continue }
            // OpenAI closes the stream with a non-JSON `[DONE]` sentinel.
            if payload == OpenAIWire.doneSentinel { break }
            guard let event = OpenAIWire.streamEvent(fromData: Data(payload.utf8)) else {
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

  private static func checkStatus(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw ModelClientError.http(
        status: http.statusCode, message: OpenAIWire.errorMessage(from: data)
      )
    }
  }

  private static func checkStreamStatus(
    _ response: URLResponse, bytes: URLSession.AsyncBytes
  ) async throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      var data = Data()
      for try await byte in bytes { data.append(byte) }
      throw ModelClientError.http(
        status: http.statusCode, message: OpenAIWire.errorMessage(from: data)
      )
    }
  }
}
