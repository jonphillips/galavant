import GalavantAI
import GalavantChat
import SwiftUI

/// The context-aware chat panel (ADR-0017). Presented via `.chatPanel(...)` as an
/// inspector — a trailing side column on iPad/Mac (regular width) and an adaptive
/// sheet on iPhone — so it never nests a `NavigationStack` in the split detail
/// (`ipad-nested-navigationstack-trap`). On-device is the private default; the
/// frontier tier is opt-in and explicitly flagged as leaving the device.
struct ChatPanelView: View {
  @State private var model: ChatModel
  @State private var draft = ""
  @Environment(\.dismiss) private var dismiss
  @FocusState private var inputFocused: Bool

  init(context: ChatContext) {
    _model = State(initialValue: ChatModel(context: context))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        transcript
        Divider()
        composer
      }
      .navigationTitle("Discuss")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { tierMenu }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  // MARK: - Transcript

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if model.messages.isEmpty {
            emptyState
          }
          ForEach(model.messages) { message in
            ChatBubble(message: message).id(message.id)
          }
          if model.isResponding {
            HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
              .font(.footnote)
              .id("thinking")
          }
          if let error = model.errorText {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .padding()
      }
      .onChange(of: model.messages.count) { scrollToBottom(proxy) }
      .onChange(of: model.isResponding) { scrollToBottom(proxy) }
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    withAnimation {
      if model.isResponding {
        proxy.scrollTo("thinking", anchor: .bottom)
      } else if let last = model.messages.last {
        proxy.scrollTo(last.id, anchor: .bottom)
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Ask about \(model.context.title).")
        .font(.headline)
      Text(
        "Answers stay on this device unless you switch to Claude. "
          + "Ask anything about what's on screen, or about the wider pool.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(spacing: 6) {
      privacyBanner
      HStack(spacing: 8) {
        TextField("Message", text: $draft, axis: .vertical)
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
          .focused($inputFocused)
          .onSubmit(send)
        Button(action: send) {
          Image(systemName: "arrow.up.circle.fill").font(.title2)
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResponding)
      }
    }
    .padding()
  }

  /// The explicit "where does this go" affordance (ADR-0017 §4).
  private var privacyBanner: some View {
    HStack(spacing: 6) {
      if model.sendsToProvider {
        Icon.aiFrontier.image.foregroundStyle(.blue)
        Text("Messages and the on-screen context are sent to \(model.selectedProvider.displayName).")
      } else {
        Icon.aiOnDevice.image.foregroundStyle(.green)
        Text("Private — this conversation stays on your device.")
      }
      Spacer()
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  /// On-device (the private default) plus one entry per frontier provider — the
  /// per-conversation model switcher (ADR-0014 multi-provider amendment). A
  /// provider without a key is shown disabled so you know it exists.
  private var tierMenu: some View {
    Menu {
      Button {
        model.useFrontier = false
      } label: {
        Label("On-device (private)", systemImage: Icon.aiOnDevice.systemName)
        if !model.sendsToProvider { Image(systemName: Icon.checkmark.systemName) }
      }
      ForEach(FrontierProvider.allCases) { provider in
        Button {
          model.selectedProvider = provider
          model.useFrontier = true
        } label: {
          Label(
            "\(provider.displayName) (sends data off device)",
            systemImage: Icon.aiFrontier.systemName
          )
          if model.sendsToProvider, model.selectedProvider == provider {
            Image(systemName: Icon.checkmark.systemName)
          }
        }
        .disabled(!model.availableProviders.contains(provider))
      }
    } label: {
      (model.sendsToProvider ? Icon.aiFrontier : Icon.aiOnDevice).image
        .foregroundStyle(model.sendsToProvider ? .blue : .green)
    }
  }

  private func send() {
    let text = draft
    draft = ""
    Task { await model.send(text) }
  }
}

/// One chat turn — user right-aligned, assistant left-aligned.
private struct ChatBubble: View {
  let message: ChatMessage

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 32) }
      Text(message.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          message.role == .user
            ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)),
          in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
      if message.role == .assistant { Spacer(minLength: 32) }
    }
  }
}

extension View {
  /// Attach the chat panel as an inspector keyed off `isPresented`, seeded with
  /// the screen's `ChatContext`.
  func chatPanel(isPresented: Binding<Bool>, context: @autoclosure @escaping () -> ChatContext)
    -> some View
  {
    inspector(isPresented: isPresented) {
      ChatPanelView(context: context())
        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
    }
  }
}
