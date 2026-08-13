import LLMClientKit
import GalavantChat
import GalavantSchema
import Sharing
import SwiftUI
import UIKit

/// The AI portion of Settings: the BYO-key frontier tier (ADR-0014 §4 + the
/// multi-provider amendment). Enter or clear a key per provider (Claude, ChatGPT);
/// the model switcher then offers each configured provider per conversation. Absent
/// any key, the screen is explicit that on-device is the only tier.
///
/// Sections only — no `Form`/`NavigationStack` of its own, so it drops into the
/// `SettingsScreen` form alongside the other settings sections.
struct AISettingsSections: View {
  @State private var model = AISettingsModel()
  /// The editable chat pre-prompt (ADR-0031 §6). Persisted to the same shared-defaults
  /// key `ChatModel` reads live, so an edit here shapes the next conversation.
  @Shared(.appStorage(chatCustomInstructionsKey)) private var chatInstructions = ""
  @State private var copiedRecommendationContract = false

  var body: some View {
    Group {
      tierStatusSection
      ForEach(model.providers) { provider in
        keySection(for: provider)
      }
      instructionsSection
      recommendationHandoffSection
    }
    .onAppear { model.onAppear() }
  }

  private var recommendationHandoffSection: some View {
    Section {
      Button {
        UIPasteboard.general.string = RecommendationHandoffContract.projectInstructions
        copiedRecommendationContract = true
      } label: {
        Label(
          copiedRecommendationContract ? "Project Instructions Copied" : "Copy Project Instructions",
          systemImage: "doc.on.doc"
        )
      }
    } header: {
      Text("Recommendation handoff")
    } footer: {
      Text("Paste these once into your ChatGPT or Claude project instructions. Galavant’s recommendation brief stays short and the returned JSON is version-checked.")
    }
  }

  /// A free-text pre-prompt spliced into every chat's system prompt — Jon's "let me
  /// tune the assistant" surface. Standing guidance ("always suggest links and images
  /// when available"), not a per-message ask.
  private var instructionsSection: some View {
    Section {
      TextField(
        "e.g. Always include a link for each suggestion, and prefer walkable clusters.",
        text: Binding($chatInstructions),
        axis: .vertical
      )
      .lineLimit(3...8)
      if !chatInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button("Clear", role: .destructive) { $chatInstructions.withLock { $0 = "" } }
      }
    } header: {
      Text("Chat instructions")
    } footer: {
      Text(
        "Added to every Discuss conversation as standing guidance. Leave blank for the "
          + "default. Applies on the next conversation you open.")
    }
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
      if let preview = model.keyPreview(for: provider) {
        LabeledContent("Stored") {
          Text(preview).monospaced().foregroundStyle(.secondary)
        }
      }
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
