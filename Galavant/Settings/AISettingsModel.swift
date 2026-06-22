import Dependencies
import GalavantAI
import Observation

/// Drives the AI settings stub: enter or clear the device-local frontier key
/// (ADR-0014 §1). The substantive logic — Keychain storage and tier degradation —
/// lives and is tested in `GalavantAI`; this model is the thin shell that loads
/// the current state and writes edits, named after the user's actions
/// (STYLE §2). Lives in the app's untestable target deliberately: it only
/// orchestrates the already-tested `APIKeyStore`.
@MainActor
@Observable
final class AISettingsModel {
  /// The editable key field. Blank until the user types; never pre-filled with the
  /// stored secret (we only ever report whether one exists).
  var keyInput = ""
  /// Whether a key is currently stored — drives the "frontier enabled" copy and
  /// the on-device-only fallback message.
  private(set) var hasStoredKey = false

  @ObservationIgnored @Dependency(\.apiKeyStore) private var keyStore

  /// The frontier provider this stub manages. Anthropic-only in v1 (ADR-0014 §2).
  let provider: FrontierProvider = .anthropic

  func onAppear() {
    hasStoredKey = keyStore.key(provider) != nil
  }

  /// Whether the typed key is worth saving (non-blank).
  var canSave: Bool {
    !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func saveButtonTapped() {
    keyStore.setKey(keyInput, for: provider)
    keyInput = ""
    hasStoredKey = keyStore.key(provider) != nil
  }

  func clearButtonTapped() {
    keyStore.setKey(nil, for: provider)
    keyInput = ""
    hasStoredKey = false
  }
}
