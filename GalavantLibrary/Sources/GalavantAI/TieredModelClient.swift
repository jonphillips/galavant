import Dependencies
import Foundation

/// The tiered boundary itself (ADR-0014 §3): holds the on-device backend and an
/// *optional* frontier backend, and routes each request by its preferred tier.
/// When a frontier request arrives but no key is configured, it **degrades to
/// on-device** rather than failing — "if no frontier key is present, the app
/// degrades to on-device only" (ADR-0014 §1). Resolution is a pure function so
/// the degradation is unit-testable with stubs.
public struct TieredModelClient: ModelClient {
  let onDevice: any ModelClient
  let frontier: (any ModelClient)?

  public init(onDevice: any ModelClient, frontier: (any ModelClient)?) {
    self.onDevice = onDevice
    self.frontier = frontier
  }

  /// Whether the frontier tier is usable (a key is configured). Drives the
  /// settings/chat UI: absent a key, frontier options are disabled and on-device
  /// is offered instead.
  public var isFrontierAvailable: Bool { frontier != nil }

  /// The backend that will actually serve a request for `tier` — on-device for
  /// `.onDevice`, and for `.frontier` the frontier backend when present, else
  /// on-device (the named degradation).
  func backend(for tier: ModelTier) -> any ModelClient {
    switch tier {
    case .onDevice: return onDevice
    case .frontier: return frontier ?? onDevice
    }
  }

  public func complete(_ request: ModelRequest) async throws -> ModelResponse {
    try await backend(for: request.tier).complete(request)
  }

  public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error> {
    backend(for: request.tier).stream(request)
  }
}

extension TieredModelClient {
  /// The live boundary: on-device FoundationModels, plus the Anthropic frontier
  /// **only when** a key is in the Keychain. Reading the key store here is what
  /// makes "no key → on-device path only" a property of the dependency graph
  /// rather than every call site.
  public static var live: TieredModelClient {
    @Dependency(\.apiKeyStore) var keyStore
    let frontier: (any ModelClient)? = keyStore.key(.anthropic)
      .map { AnthropicModelClient(apiKey: $0) }
    return TieredModelClient(onDevice: OnDeviceModelClient.live, frontier: frontier)
  }
}

/// A deterministic backend for tests and previews: no network, no device model.
/// `echo` replays the last user turn so a test can assert text flowed through the
/// `ModelClient` protocol (both `complete` and `stream`).
public struct StubModelClient: ModelClient {
  let respond: @Sendable (ModelRequest) async throws -> ModelResponse

  public init(respond: @escaping @Sendable (ModelRequest) async throws -> ModelResponse) {
    self.respond = respond
  }

  public func complete(_ request: ModelRequest) async throws -> ModelResponse {
    try await respond(request)
  }

  /// Streams the completed response as a single chunk — enough to exercise the
  /// streaming path deterministically without snapshotting partial state.
  public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error> {
    AsyncThrowingStream { continuation in
      let respond = self.respond
      let task = Task {
        do {
          let response = try await respond(request)
          continuation.yield(ModelChunk(text: response.text))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Replays the last user message back as the assistant response.
  public static let echo = StubModelClient { request in
    ModelResponse(text: request.messages.last(where: { $0.role == .user })?.text ?? "")
  }

  /// Always returns a fixed string — handy when the assertion is "did the call
  /// reach the model" rather than "what came back".
  public static func constant(_ text: String) -> StubModelClient {
    StubModelClient { _ in ModelResponse(text: text) }
  }
}
