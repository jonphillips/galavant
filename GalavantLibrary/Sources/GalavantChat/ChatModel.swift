import Dependencies
import Foundation
import GalavantAI
import Observation

/// One displayed chat turn. Ephemeral (ADR-0017 §4) — held in memory for the
/// session, never persisted or CloudKit-synced.
public struct ChatMessage: Identifiable, Sendable, Equatable {
  public enum Role: Sendable, Equatable { case user, assistant }
  public let id: UUID
  public var role: Role
  public var text: String

  public init(id: UUID = UUID(), role: Role, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }
}

/// Drives the context-aware chat (ADR-0017). Holds the seeded `ChatContext`, the
/// per-conversation tier choice, and an ephemeral message list; talks to the
/// tiered `ModelClient`. On-device is the private default and streams text;
/// frontier (opt-in, BYO-key) runs the tool-use loop over `ChatToolExecutor`
/// (on-device tool-use is limited — ADR-0017 §3). Lives in the package so the
/// dispatch + serialization logic is testable with a stub (the app target stays
/// untestable — `galavant-app-target-untestable`).
@MainActor
@Observable
public final class ChatModel {
  public let context: ChatContext
  public private(set) var messages: [ChatMessage] = []
  /// Per-conversation privacy choice (ADR-0017 §4). On-device is the default;
  /// flipping this on (when a key exists) routes the conversation to the frontier
  /// and surfaces that data leaves the device. Ignored when no key is configured.
  public var useFrontier = false
  /// Which frontier provider this conversation uses when `useFrontier` is on
  /// (ADR-0014 multi-provider amendment) — the per-conversation switch that lets
  /// you develop a plan with one model and ask another to critique it. Ignored when
  /// its key is absent (then the conversation degrades to on-device).
  public var selectedProvider: FrontierProvider = .anthropic
  public private(set) var isResponding = false
  public private(set) var errorText: String?

  @ObservationIgnored @Dependency(\.modelClient) private var modelClient
  @ObservationIgnored @Dependency(\.apiKeyStore) private var apiKeyStore
  @ObservationIgnored private let tools: ChatToolExecutor

  /// Hard cap on tool-loop turns per message, so a misbehaving model can't spin.
  private let maxToolTurns = 6

  public init(context: ChatContext, tools: ChatToolExecutor = PoolToolExecutor()) {
    self.context = context
    self.tools = tools
    // Default the switcher to whichever provider actually has a key, so a single
    // configured provider "just works" without a manual pick.
    if let first = availableProviders.first { selectedProvider = first }
  }

  /// Whether *any* frontier provider can be offered — at least one key is in the
  /// Keychain (ADR-0014 §1). Drives whether the panel shows the frontier toggle.
  public var frontierAvailable: Bool { !availableProviders.isEmpty }

  /// The frontier providers with a configured key, in stable order — drives the
  /// switcher (providers without a key aren't offered).
  public var availableProviders: [FrontierProvider] {
    FrontierProvider.allCases.filter { apiKeyStore.key($0) != nil }
  }

  /// The tier this conversation will actually use — the selected frontier provider
  /// only when chosen *and* its key is present, else the on-device default (the
  /// boundary degrades too, but the panel also keys its "data leaves the device"
  /// copy off this).
  public var activeTier: ModelTier {
    useFrontier && apiKeyStore.key(selectedProvider) != nil
      ? .frontier(selectedProvider) : .onDevice
  }

  /// True when the next message will leave the device — the explicit affordance
  /// the panel must surface before a frontier turn (ADR-0017 §4).
  public var sendsToProvider: Bool {
    if case .frontier = activeTier { return true }
    return false
  }

  /// Send a user message and produce the assistant's reply. On-device streams
  /// text; frontier runs the tool loop. No-op while already responding or on
  /// blank input.
  public func send(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isResponding else { return }
    messages.append(ChatMessage(role: .user, text: trimmed))
    isResponding = true
    errorText = nil
    defer { isResponding = false }

    if case .frontier = activeTier {
      await runToolLoop()
    } else {
      await streamReply()
    }
  }

  // MARK: - Tiers

  /// On-device (or degraded) path: stream text into a fresh assistant message.
  /// No tools — the on-device tier's tool-use is limited (ADR-0017 §3).
  private func streamReply() async {
    let request = ModelRequest(
      tier: activeTier, system: systemPrompt(), messages: history(), maxTokens: 1024)
    let index = appendAssistantPlaceholder()
    do {
      for try await chunk in modelClient.stream(request) {
        messages[index].text += chunk.text
      }
      if messages[index].text.isEmpty {
        messages[index].text = "(No response.)"
      }
    } catch {
      removePlaceholderIfEmpty(at: index)
      errorText = describe(error)
    }
  }

  /// Frontier path: the tool-use loop (ADR-0017 §3 / `claude-api`). The model may
  /// emit `tool_use`; we run the verb, return a `tool_result`, and continue until
  /// it stops calling tools or the turn cap is hit.
  private func runToolLoop() async {
    var working = history()
    let toolDefs = tools.tools()
    for _ in 0..<maxToolTurns {
      let request = ModelRequest(
        tier: activeTier, system: systemPrompt(), messages: working,
        tools: toolDefs, maxTokens: 2048)
      let response: ModelResponse
      do {
        response = try await modelClient.complete(request)
      } catch {
        errorText = describe(error)
        return
      }
      if !response.text.isEmpty {
        messages.append(ChatMessage(role: .assistant, text: response.text))
      }
      guard !response.toolCalls.isEmpty else { return }  // model is done
      // Echo the model's tool_use turn, then feed back one tool_result each.
      working.append(response.assistantMessage)
      var results: [ModelMessage.Content] = []
      for call in response.toolCalls {
        let output = await tools.run(call)
        results.append(.toolResult(toolUseID: call.id, text: output, isError: false))
      }
      working.append(ModelMessage(role: .user, content: results))
    }
    errorText = "The assistant kept working without finishing. Try rephrasing."
  }

  // MARK: - Helpers

  /// The system prompt: persona + the serialized on-screen context. The taste
  /// profile (ADR-0015) is the `ModelClient` boundary's job to inject, not the
  /// panel's (ADR-0017 §2) — so it isn't re-plumbed here.
  func systemPrompt() -> String {
    """
    You are a concise, helpful travel-planning assistant inside a private app for \
    two people planning trips together. Discuss what the user is looking at, \
    described below. For questions about the wider idea pool, use the queryPool \
    tool rather than guessing. Only use createIdea when the user clearly asks to \
    add or save a place — it lands a candidate, and the user still decides what to \
    pull onto a trip. You propose and explain; you never claim to have scheduled \
    or pulled anything yourself.

    \(context.serialized())
    """
  }

  /// The conversation so far as model messages — the display turns, text only.
  /// The API is stateless, so the full history rides each turn (ADR-0017 §4).
  private func history() -> [ModelMessage] {
    messages.map { message in
      ModelMessage(role: message.role == .user ? .user : .assistant, text: message.text)
    }
  }

  private func appendAssistantPlaceholder() -> Int {
    messages.append(ChatMessage(role: .assistant, text: ""))
    return messages.count - 1
  }

  private func removePlaceholderIfEmpty(at index: Int) {
    if index < messages.count, messages[index].role == .assistant, messages[index].text.isEmpty {
      messages.remove(at: index)
    }
  }

  private func describe(_ error: any Error) -> String {
    switch error {
    case ModelClientError.onDeviceUnavailable:
      "On-device intelligence isn't available on this device yet."
    case ModelClientError.frontierUnavailable:
      "No Claude API key is configured. Add one in Settings to chat with Claude."
    case let ModelClientError.http(status, message):
      "Claude returned an error (\(status))." + (message.map { " \($0)" } ?? "")
    default:
      "Something went wrong reaching the model."
    }
  }
}
