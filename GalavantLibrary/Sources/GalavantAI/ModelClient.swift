import Dependencies
import Foundation

/// The single seam every AI feature calls through (ADR-0014 §2). Injectable so
/// feature logic is testable with a stub and the backend (on-device vs frontier)
/// is a config choice, not a call-site choice — the same pattern as
/// `PlaceSearchClient` / `PageFetcher` / `PlaceIntelligence`
/// ([inject-io-boundaries-early]).
///
/// A request names its *preferred* `ModelTier` (`ModelRequest.tier`); the tiered
/// boundary degrades a frontier request to on-device when no key is configured
/// (`TieredModelClient`), so callers never branch on key presence.
public protocol ModelClient: Sendable {
  /// One-shot completion (extraction, classification, summarize, recommend).
  func complete(_ request: ModelRequest) async throws -> ModelResponse
  /// Token stream for the chat window — incremental text deltas.
  func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error>
}

/// Which backend a task wants. On-device is free/private/offline; frontier is the
/// user's own networked key (ADR-0014 §3). A request expresses a *preference* —
/// the boundary degrades frontier → on-device when the tier is unavailable.
public enum ModelTier: Sendable, Equatable {
  case onDevice
  case frontier(FrontierProvider)
}

/// The frontier providers behind a BYO-key. Anthropic-only in v1 (ADR-0014 §2 /
/// "open at build"); the enum keeps the boundary ready for more without a
/// call-site sweep.
public enum FrontierProvider: String, Sendable, Equatable, CaseIterable {
  case anthropic
}

/// One turn in a conversation. Roles alternate user/assistant; the system prompt
/// rides on `ModelRequest.system` (not a message), matching both the Anthropic
/// wire shape and the on-device session's instructions.
public struct ModelMessage: Sendable, Equatable {
  public enum Role: String, Sendable, Equatable {
    case user
    case assistant
  }

  public var role: Role
  public var text: String

  public init(role: Role, text: String) {
    self.role = role
    self.text = text
  }

  public static func user(_ text: String) -> ModelMessage { .init(role: .user, text: text) }
  public static func assistant(_ text: String) -> ModelMessage {
    .init(role: .assistant, text: text)
  }
}

/// A model call, backend-agnostic. The taste profile (a forthcoming ADR-0015
/// record) is injected into `system` by the boundary, not re-plumbed per feature
/// (ADR-0014 §4) — `system` is the seam it lands on.
public struct ModelRequest: Sendable, Equatable {
  /// The preferred backend; degrades to on-device when unavailable.
  public var tier: ModelTier
  /// System prompt — persona/instructions/profile. Optional.
  public var system: String?
  /// The conversation so far. Must be non-empty and start with a user turn.
  public var messages: [ModelMessage]
  /// Hard ceiling on generated tokens (Anthropic requires it; on-device ignores).
  public var maxTokens: Int

  public init(
    tier: ModelTier = .onDevice,
    system: String? = nil,
    messages: [ModelMessage],
    maxTokens: Int = 1024
  ) {
    self.tier = tier
    self.system = system
    self.messages = messages
    self.maxTokens = maxTokens
  }

  /// A single-prompt convenience for one-shot extraction/classification tasks.
  public init(
    tier: ModelTier = .onDevice,
    system: String? = nil,
    prompt: String,
    maxTokens: Int = 1024
  ) {
    self.init(tier: tier, system: system, messages: [.user(prompt)], maxTokens: maxTokens)
  }
}

/// A completed response. `text` is the concatenated assistant text; `stopReason`
/// is the backend's stop signal (`end_turn` / `max_tokens` / `refusal` / …) when
/// it reports one.
public struct ModelResponse: Sendable, Equatable {
  public var text: String
  public var stopReason: String?

  public init(text: String, stopReason: String? = nil) {
    self.text = text
    self.stopReason = stopReason
  }
}

/// One streamed delta — an incremental piece of assistant text.
public struct ModelChunk: Sendable, Equatable {
  public var text: String

  public init(text: String) {
    self.text = text
  }
}

/// Expected failures are values (STYLE §5). Network/transport errors surface as
/// `URLError`; these cover the model-API-specific cases.
public enum ModelClientError: Error, Equatable, Sendable {
  /// The frontier tier was required but no key is configured.
  case frontierUnavailable
  /// The on-device model is off, unsupported, or still downloading.
  case onDeviceUnavailable
  /// The provider returned a non-success HTTP status with an optional message.
  case http(status: Int, message: String?)
  /// The response body didn't decode into the expected shape.
  case malformedResponse
}

// MARK: - Dependency

extension DependencyValues {
  /// The boundary every AI feature reads. Lives behind `any ModelClient` so the
  /// backend is swappable; the live value assembles the tiered client from the
  /// Keychain key store (frontier present only when a key exists).
  public var modelClient: any ModelClient {
    get { self[ModelClientKey.self] }
    set { self[ModelClientKey.self] = newValue }
  }
}

private enum ModelClientKey: DependencyKey {
  static var liveValue: any ModelClient { TieredModelClient.live }
  static var testValue: any ModelClient {
    TieredModelClient(onDevice: StubModelClient.echo, frontier: nil)
  }
}
