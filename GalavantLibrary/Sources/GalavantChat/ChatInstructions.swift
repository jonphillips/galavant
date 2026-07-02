import Dependencies
import Foundation

/// The shared-defaults key the Settings editor writes (via `@Shared(.appStorage)`)
/// and the live `ChatInstructions` reads. One key, both sides — no app-side
/// dependency registration needed.
public let chatCustomInstructionsKey = "chatCustomInstructions"

/// User-editable "house instructions" prepended to every chat system prompt
/// (ADR-0031 §6 — the editable pre-prompt Jon wanted so he can tune the assistant).
/// Injectable so the system-prompt assembly stays testable; the live value reads the
/// app's shared defaults so a Settings edit takes effect on the next conversation.
public struct ChatInstructions: Sendable {
  public var current: @Sendable () -> String

  public init(current: @escaping @Sendable () -> String) {
    self.current = current
  }
}

extension ChatInstructions: DependencyKey {
  /// Reads the same `UserDefaults` key the Settings editor writes. `UserDefaults`
  /// is process-wide, so the package sees the app's edits without extra wiring.
  public static let liveValue = ChatInstructions {
    UserDefaults.standard.string(forKey: chatCustomInstructionsKey) ?? ""
  }

  /// Empty by default under test/preview, so seeded context stays deterministic.
  public static let testValue = ChatInstructions { "" }
  public static let previewValue = ChatInstructions { "" }
}

extension DependencyValues {
  public var chatInstructions: ChatInstructions {
    get { self[ChatInstructions.self] }
    set { self[ChatInstructions.self] = newValue }
  }
}
