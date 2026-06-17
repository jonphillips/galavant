import GalavantPlaces
import GalavantSchema
import SwiftUI

/// The confirm-and-tweak sheet shown when you share a page (Jon's choice: vet
/// captures at the source). The `CaptureModel` does the parse + Apple Maps match;
/// this view just binds its editable draft and saves. A focused form — not the
/// app's full `IdeaFormView` (that lives in the app target, unreachable here).
struct CaptureConfirmView: View {
  @Bindable var model: CaptureModel
  /// Called to tear the extension down (after save, or on cancel).
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Add to Galavant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onClose)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { await model.save() } }
              .disabled(!isSavable)
          }
        }
    }
    .task { await model.prepare() }
    .onChange(of: model.phase) { _, phase in
      if phase == .saved { onClose() }
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .preparing:
      ProgressView("Reading page…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    default:
      form
    }
  }

  private var form: some View {
    Form {
      Section("Place") {
        TextField("Name", text: $model.draft.name)
        Picker("Kind", selection: $model.draft.kind) {
          Text("Unspecified").tag(IdeaKind?.none)
          ForEach(IdeaKind.allCases, id: \.self) { kind in
            Label(kind.label, systemImage: kind.systemImage).tag(IdeaKind?.some(kind))
          }
        }
      }

      Section("Location") {
        Text(locationSummary)
          .foregroundStyle(hasLocation ? .primary : .secondary)
      }

      Section("Notes") {
        TextField("Notes", text: $model.draft.notes, axis: .vertical)
          .lineLimit(1...5)
      }

      if !model.draft.url.isEmpty {
        Section("Link") {
          Text(model.draft.url)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      if case let .failed(message) = model.phase {
        Section {
          Text(message).foregroundStyle(.red)
        }
      }
    }
  }

  private var isSavable: Bool {
    !model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && model.phase != .saving
  }

  private var hasLocation: Bool {
    model.draft.latitude != nil || model.draft.address != nil
  }

  private var locationSummary: String {
    if let address = model.draft.address { return address }
    if let lat = model.draft.latitude, let lon = model.draft.longitude {
      return String(format: "%.4f, %.4f", lat, lon)
    }
    return "No location found — add it in the app"
  }
}
