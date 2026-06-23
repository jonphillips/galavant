import GalavantAI
import SwiftUI

/// The settings surface for the BYO-key frontier tier (ADR-0014 §4 + the
/// multi-provider amendment). Enter or clear a key per provider (Claude, ChatGPT);
/// the model switcher then offers each configured provider per conversation.
/// Absent any key, the screen is explicit that on-device is the only tier.
struct AISettingsView: View {
  @State private var model = AISettingsModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        tierStatusSection
        ForEach(model.providers) { provider in
          keySection(for: provider)
        }
      }
      .navigationTitle("AI")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .onAppear { model.onAppear() }
  }

  private var tierStatusSection: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text("On-device").font(.body)
          Text("Private and offline. Always available.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Icon.aiOnDevice.image.foregroundStyle(.green)
      }
      ForEach(model.providers) { provider in
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Frontier (\(provider.displayName))").font(.body)
            Text(
              model.hasStoredKey(provider)
                ? "Enabled with your key. Sends context off device."
                : "Add your key below to enable. Off until then."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
        } icon: {
          Icon.aiFrontier.image
            .foregroundStyle(model.hasStoredKey(provider) ? .blue : .secondary)
        }
      }
    } header: {
      Text("Model tiers")
    } footer: {
      Text(
        "On-device runs free and private. Each frontier provider uses your own API "
          + "key — its cost is yours, and a frontier request sends the conversation to "
          + "that provider. Configure more than one to switch models per conversation "
          + "(and to stay usable if one runs out). No key is shared with your travel party."
      )
    }
  }

  private func keySection(for provider: FrontierProvider) -> some View {
    Section {
      SecureField(Self.placeholder(for: provider), text: keyBinding(for: provider))
        .textContentType(.password)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Save Key") { model.save(provider) }
        .disabled(!model.canSave(provider))
      if model.hasStoredKey(provider) {
        Button("Clear Key", role: .destructive) { model.clear(provider) }
      }
    } header: {
      Text("\(provider.displayName) API key")
    } footer: {
      Text(
        model.hasStoredKey(provider)
          ? "A key is stored on this device. Saving a new one replaces it."
          : "Stored in the Keychain on this device only, synced across your own "
            + "devices by iCloud Keychain."
      )
    }
  }

  private func keyBinding(for provider: FrontierProvider) -> Binding<String> {
    Binding(
      get: { model.keyInput(for: provider) },
      set: { model.setKeyInput($0, for: provider) }
    )
  }

  private static func placeholder(for provider: FrontierProvider) -> String {
    switch provider {
    case .anthropic: "sk-ant-…"
    case .openai: "sk-…"
    }
  }
}

#Preview {
  AISettingsView()
}
