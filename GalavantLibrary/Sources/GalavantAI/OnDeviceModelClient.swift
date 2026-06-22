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
    guard case .available = SystemLanguageModel.default.availability else {
      throw ModelClientError.onDeviceUnavailable
    }
    let session = LanguageModelSession(instructions: request.system ?? "")
    let response = try await session.respond(to: Self.prompt(from: request.messages))
    return ModelResponse(text: response.content, stopReason: "end_turn")
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
