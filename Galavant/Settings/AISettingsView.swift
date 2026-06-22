import GalavantAI
import SwiftUI

/// The minimal settings surface for the BYO-key frontier tier (ADR-0014 slice 4).
/// A stub home for what the "You"/settings area will eventually hold — enough to
/// enter and clear the Anthropic key so the frontier tier can light up on device.
/// Absent a key, the screen is explicit that on-device is the only tier.
struct AISettingsView: View {
  @State private var model = AISettingsModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        tierStatusSection
        keySection
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
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text("Frontier (Claude)").font(.body)
          Text(
            model.hasStoredKey
              ? "Enabled with your key. Sends context to Anthropic."
              : "Add your key below to enable. Off until then."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      } icon: {
        Icon.aiFrontier.image.foregroundStyle(model.hasStoredKey ? .blue : .secondary)
      }
    } header: {
      Text("Model tiers")
    } footer: {
      Text(
        "On-device runs free and private. The frontier tier uses your own Anthropic "
          + "API key — its cost is yours, and a frontier request sends the conversation "
          + "to Anthropic. No key is ever shared with your travel party."
      )
    }
  }

  private var keySection: some View {
    Section {
      SecureField("sk-ant-…", text: $model.keyInput)
        .textContentType(.password)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      Button("Save Key") { model.saveButtonTapped() }
        .disabled(!model.canSave)
      if model.hasStoredKey {
        Button("Clear Key", role: .destructive) { model.clearButtonTapped() }
      }
    } header: {
      Text("Anthropic API key")
    } footer: {
      Text(
        model.hasStoredKey
          ? "A key is stored on this device. Saving a new one replaces it."
          : "Stored in the Keychain on this device only, synced across your own "
            + "devices by iCloud Keychain."
      )
    }
  }
}

#Preview {
  AISettingsView()
}
