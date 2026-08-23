import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct RecommendationWorkspaceImageDropWell: View {
  let model: RecommendationWorkspaceModel
  @State private var isTargeted = false

  private var candidateTitle: String {
    model.activeCandidate?.title ?? "candidate"
  }

  private var canAcceptDrop: Bool {
    model.activeCandidate?.idea != nil
  }

  var body: some View {
    // One compact row: the card above already names the candidate, so the well is
    // just the drop hint + Paste, keeping the strip card short.
    HStack(spacing: 8) {
      Label(
        canAcceptDrop ? "Drop a photo" : "Resolve first to add photos",
        systemImage: canAcceptDrop ? "photo.badge.plus" : "photo.slash"
      )
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 4)
      PasteButton(supportedContentTypes: [.image]) { providers in
        Task {
          for provider in providers {
            guard let pastedImage = await droppedImage(from: provider) else {
              model.imageDropProviderFailed()
              continue
            }
            await model.attachDroppedImage(
              pastedImage.data,
              sourceURL: pastedImage.url?.absoluteString
            )
          }
        }
      }
      .labelStyle(.iconOnly)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
      .disabled(!canAcceptDrop)
      .accessibilityLabel("Paste photo to \(candidateTitle)")
    }
    .foregroundStyle(canAcceptDrop ? .primary : .secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(
          isTargeted && canAcceptDrop
            ? Color.accentColor.opacity(0.22)
            : canAcceptDrop
              ? Color.black.opacity(0.08)
              : Color.secondary.opacity(0.12)
        )
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          isTargeted && canAcceptDrop ? Color.accentColor : Color.clear,
          lineWidth: 2
        )
    }
    .contentShape(Rectangle())
    .onDrop(of: [.image, .url], isTargeted: $isTargeted) { providers in
      guard canAcceptDrop else { return false }
      Task {
        for provider in providers {
          guard let droppedImage = await droppedImage(from: provider) else {
            model.imageDropProviderFailed()
            continue
          }
          await model.attachDroppedImage(droppedImage.data, sourceURL: droppedImage.url?.absoluteString)
        }
      }
      return true
    }
    .disabled(!canAcceptDrop)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Add photo to \(candidateTitle)")
    .accessibilityHint(
      canAcceptDrop
        ? "Drop or paste an image from the research browser."
        : "Resolve this candidate first to add photos."
    )
  }

  private struct DroppedImage {
    let data: Data
    let url: URL?
  }

  private func droppedImage(from provider: NSItemProvider) async -> DroppedImage? {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      guard let data = await loadImageData(from: provider) else { return nil }
      return DroppedImage(data: data, url: await loadURL(from: provider))
    }

    guard
      provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
      let url = await loadURL(from: provider),
      let (data, _) = try? await URLSession.shared.data(from: url)
    else {
      return nil
    }
    return DroppedImage(data: data, url: url)
  }

  private func loadImageData(from provider: NSItemProvider) async -> Data? {
    await loadData(from: provider, typeIdentifier: UTType.image.identifier)
  }

  private func loadURL(from provider: NSItemProvider) async -> URL? {
    guard let data = await loadData(from: provider, typeIdentifier: UTType.url.identifier) else {
      return nil
    }
    if let url = URL(dataRepresentation: data, relativeTo: nil) {
      return url
    }
    guard let string = String(data: data, encoding: .utf8) else { return nil }
    return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }
}
