import Dependencies
import GalavantAI
import Observation

/// Drives the AI settings surface: enter or clear the device-local frontier key
/// for each provider (ADR-0014 §1 + the multi-provider amendment). The substantive
/// logic — Keychain storage and tier degradation — lives and is tested in
/// `GalavantAI`; this model is the thin shell that loads current state and writes
/// edits. Lives in the app's untestable target deliberately: it only orchestrates
/// the already-tested `APIKeyStore`.
@MainActor
@Observable
final class AISettingsModel {
  /// Editable key fields, per provider. Blank until the user types; never
  /// pre-filled with a stored secret (we only report whether one exists).
  var keyInputs: [FrontierProvider: String] = [:]
  /// Which providers currently have a stored key — drives the "enabled" copy.
  private(set) var storedProviders: Set<FrontierProvider> = []

  @ObservationIgnored @Dependency(\.apiKeyStore) private var keyStore

  /// Every provider the switcher can offer, in stable order.
  let providers = FrontierProvider.allCases

  func onAppear() { refresh() }

  private func refresh() {
    storedProviders = Set(providers.filter { keyStore.key($0) != nil })
  }

  func hasStoredKey(_ provider: FrontierProvider) -> Bool {
    storedProviders.contains(provider)
  }

  func keyInput(for provider: FrontierProvider) -> String {
    keyInputs[provider] ?? ""
  }

  func setKeyInput(_ value: String, for provider: FrontierProvider) {
    keyInputs[provider] = value
  }

  func canSave(_ provider: FrontierProvider) -> Bool {
    !keyInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func save(_ provider: FrontierProvider) {
    keyStore.setKey(keyInputs[provider], for: provider)
    keyInputs[provider] = ""
    refresh()
  }

  func clear(_ provider: FrontierProvider) {
    keyStore.setKey(nil, for: provider)
    keyInputs[provider] = ""
    refresh()
  }
}
