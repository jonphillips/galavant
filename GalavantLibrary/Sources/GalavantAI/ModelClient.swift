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

/// The frontier providers behind a BYO-key (ADR-0014 §2 + the 2026-06-23
/// multi-provider amendment). `CaseIterable` so the settings/chat switcher
/// enumerates providers for free; each gets its own Keychain slot (`APIKeyStore`).
public enum FrontierProvider: String, Sendable, Equatable, CaseIterable, Identifiable {
  case anthropic
  case openai

  public var id: String { rawValue }

  /// User-facing name for the switcher.
  public var displayName: String {
    switch self {
    case .anthropic: "Claude"
    case .openai: "ChatGPT"
    }
  }
}

/// One turn in a conversation. Roles alternate user/assistant; the system prompt
/// rides on `ModelRequest.system` (not a message), matching both the Anthropic
/// wire shape and the on-device session's instructions.
///
/// Content is a list of blocks so the tool-use loop can round-trip: an assistant
/// turn carries `.text` + `.toolUse` blocks, and the following user turn carries
/// the matching `.toolResult` blocks (ADR-0017 §3). Plain text turns stay simple
/// via the `.user`/`.assistant(_:)` helpers and the `text` accessor.
public struct ModelMessage: Sendable, Equatable {
  public enum Role: String, Sendable, Equatable {
    case user
    case assistant
  }

  /// One piece of a message. The Anthropic wire encodes these as content blocks;
  /// the on-device tier only ever sees `.text`.
  public enum Content: Sendable, Equatable {
    case text(String)
    /// An assistant request to call a tool (`tool_use`).
    case toolUse(ModelToolCall)
    /// A user-turn reply carrying a tool's output (`tool_result`).
    case toolResult(toolUseID: String, text: String, isError: Bool)
  }

  public var role: Role
  public var content: [Content]

  public init(role: Role, content: [Content]) {
    self.role = role
    self.content = content
  }

  public init(role: Role, text: String) {
    self.init(role: role, content: [.text(text)])
  }

  /// The concatenated text of this message's `.text` blocks — what the on-device
  /// prompt and the stub backends read; tool blocks contribute nothing.
  public var text: String {
    content.compactMap { if case let .text(value) = $0 { value } else { nil } }.joined()
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
  /// Tools the model may call (ADR-0017 §3). Empty for plain completions; the
  /// on-device tier ignores them (its tool-use is limited).
  public var tools: [ModelTool]
  /// Hard ceiling on generated tokens (Anthropic requires it; on-device ignores).
  public var maxTokens: Int
  /// When set, attach Anthropic's server-side `web_search` tool with this `max_uses`
  /// cap (ADR-0018, M6e discovery). Frontier-tier only — the on-device tier can't
  /// web-search, so the backend ignores it. `nil` = no web search.
  public var webSearchMaxUses: Int?

  public init(
    tier: ModelTier = .onDevice,
    system: String? = nil,
    messages: [ModelMessage],
    tools: [ModelTool] = [],
    maxTokens: Int = 1024,
    webSearchMaxUses: Int? = nil
  ) {
    self.tier = tier
    self.system = system
    self.messages = messages
    self.tools = tools
    self.maxTokens = maxTokens
    self.webSearchMaxUses = webSearchMaxUses
  }

  /// A single-prompt convenience for one-shot extraction/classification tasks.
  public init(
    tier: ModelTier = .onDevice,
    system: String? = nil,
    prompt: String,
    maxTokens: Int = 1024,
    webSearchMaxUses: Int? = nil
  ) {
    self.init(
      tier: tier, system: system, messages: [.user(prompt)],
      maxTokens: maxTokens, webSearchMaxUses: webSearchMaxUses
    )
  }
}

/// A completed response. `text` is the concatenated assistant text; `toolCalls`
/// are any `tool_use` blocks the model emitted (drives the tool loop, ADR-0017 §3);
/// `stopReason` is the backend's stop signal (`end_turn` / `tool_use` /
/// `max_tokens` / `refusal` / …) when it reports one.
public struct ModelResponse: Sendable, Equatable {
  public var text: String
  public var toolCalls: [ModelToolCall]
  public var stopReason: String?

  public init(text: String, toolCalls: [ModelToolCall] = [], stopReason: String? = nil) {
    self.text = text
    self.toolCalls = toolCalls
    self.stopReason = stopReason
  }

  /// The assistant message to append to the conversation before sending tool
  /// results back — its text plus a `.toolUse` block per call, in order. Used by
  /// the tool loop to echo the model's turn (the wire requires the originating
  /// `tool_use` blocks precede their `tool_result`s).
  public var assistantMessage: ModelMessage {
    var content: [ModelMessage.Content] = text.isEmpty ? [] : [.text(text)]
    content += toolCalls.map { .toolUse($0) }
    return ModelMessage(role: .assistant, content: content)
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
