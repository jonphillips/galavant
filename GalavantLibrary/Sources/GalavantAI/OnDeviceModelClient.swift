import Foundation
import FoundationModels

/// The on-device tier (ADR-0014 §3): free, private, offline. Wraps Apple's
/// `FoundationModels` — the same plumbing M4d introduced as `PlaceIntelligence`,
/// now generalized behind the shared `ModelClient` boundary rather than a
/// place-specific one-off. The default backend for anything cheap or private, and
/// the degradation target when no frontier key is configured.
///
/// FoundationModels lives only behind these methods; if the model is off,
/// unsupported, or still downloading, calls throw `.onDeviceUnavailable` so the
/// caller can surface that state (rather than silently producing nothing).
public struct OnDeviceModelClient: ModelClient {
  public init() {}

  public static let live = OnDeviceModelClient()

  public func complete(_ request: ModelRequest) async throws -> ModelResponse {
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
      throw ModelClientError.onDeviceUnavailable
    }
    let session = LanguageModelSession(instructions: request.system ?? "")
    // System + prompt + generated output must all fit the model's context window
    // (`contextSize`; overflow throws `contextSizeExceeded`). Fit the prompt to what's
    // left after reserving the system text and the requested output, so any caller —
    // a whole-page extract, a long chat — degrades to a shorter prompt instead of a
    // hard failure. Read the window from the model, so we track whatever the installed
    // OS reports rather than pinning a number.
    let prompt = Self.fit(
      prompt: Self.prompt(from: request.messages),
      reservingSystem: request.system ?? "",
      andOutput: request.maxTokens,
      toWindow: model.contextSize
    )
    let response = try await session.respond(to: prompt)
    return ModelResponse(text: response.content, stopReason: "end_turn")
  }

  /// Bytes-per-token estimate for Latin-script text. Deliberately on the low side
  /// (treating text as token-dense) so the fit **under**-fills the window: a wrong
  /// guess yields a slightly shorter prompt, never a `contextSizeExceeded` throw.
  static let approxCharsPerToken = 4
  /// Slice of the window held back for tokenizer drift, special tokens, and the
  /// chat template's own framing — belt to the char-estimate's suspenders.
  static let windowSafetyMargin = 0.9

  /// Clamp `prompt` to the character budget the context `window` leaves once the
  /// `system` text and `output` tokens are reserved. Pure and deterministic — the
  /// I/O lives in `complete`. Keeps the head (instructions ride in `system`, which is
  /// preserved whole; only the tail of the page text is at risk, and only on a page
  /// far larger than any real place page). Returns `prompt` untouched when it fits.
  static func fit(prompt: String, reservingSystem system: String, andOutput output: Int, toWindow window: Int)
    -> String
  {
    let reservedTokens = output + tokenEstimate(system)
    let promptTokenBudget = max(0, window - reservedTokens)
    let charBudget = Int(Double(promptTokenBudget * approxCharsPerToken) * windowSafetyMargin)
    guard prompt.count > charBudget else { return prompt }
    let clipped = prompt.prefix(charBudget)
    if let lastSpace = clipped.lastIndex(of: " ") { return String(clipped[..<lastSpace]) }
    return String(clipped)
  }

  /// A conservative token count for `text` under `approxCharsPerToken`, rounded up so
  /// short reserves are never estimated as zero.
  static func tokenEstimate(_ text: String) -> Int {
    (text.count + approxCharsPerToken - 1) / approxCharsPerToken
  }

  /// On-device streaming yields the completed answer as a single chunk. The
  /// frontier tier is the real token-by-token path for the chat window;
  /// `FoundationModels` partial snapshots are cumulative and easy to mishandle,
  /// so the substrate keeps the on-device stream correct-and-simple.
  public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let response = try await complete(request)
          continuation.yield(ModelChunk(text: response.text))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Render the conversation into one prompt. A lone user turn passes through
  /// verbatim; multi-turn history is labelled so the on-device session has the
  /// prior context even though we construct it statelessly per call.
  static func prompt(from messages: [ModelMessage]) -> String {
    let userTurns = messages.filter { $0.role == .user }
    if messages.count == 1, let only = messages.first, only.role == .user {
      return only.text
    }
    if userTurns.count == 1, messages.allSatisfy({ $0.role == .user }) {
      return userTurns.map(\.text).joined(separator: "\n\n")
    }
    return messages.map { message in
      switch message.role {
      case .user: return "User: \(message.text)"
      case .assistant: return "Assistant: \(message.text)"
      }
    }.joined(separator: "\n\n")
  }
}
