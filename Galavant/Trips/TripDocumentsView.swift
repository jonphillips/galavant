import Foundation
import GalavantSchema
import SwiftUI
import UniformTypeIdentifiers

struct TripDocumentsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: TripDocumentsModel
  @State private var renameTitle = ""

  init(tripID: Trip.ID) {
    _model = State(initialValue: TripDocumentsModel(tripID: tripID))
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Group {
        if model.documents.isEmpty {
          ContentUnavailableView(
            "No Documents",
            systemImage: "doc.text",
            description: Text("Paste research notes or a Chat summary to keep them with this trip."))
        } else {
          List {
            ForEach(model.documents) { document in
              NavigationLink {
                TripDocumentViewer(document: document)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(document.title)
                    .font(.headline)
                  Text(document.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
              }
              .contextMenu {
                Button("Rename…", systemImage: "pencil") {
                  model.destination = .rename(document)
                  renameTitle = document.title
                }
                Button("Delete…", systemImage: "trash", role: .destructive) {
                  model.destination = .confirmDelete(document)
                }
              }
              .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                  model.destination = .confirmDelete(document)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Documents")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Add", systemImage: "plus") { model.destination = .add }
        }
      }
      .sheet(isPresented: Binding(
        get: { model.destination?.is(\.add) ?? false },
        set: { if !$0 { model.destination = nil } }
      )) {
        TripDocumentEditorSheet(model: model)
      }
      .alert("Rename Document", isPresented: Binding(
        get: { model.destination?.is(\.rename) ?? false },
        set: { if !$0 { model.destination = nil } }
      )) {
        TextField("Title", text: $renameTitle)
        Button("Save") {
          if case let .rename(document) = model.destination {
            do { try model.rename(document.id, title: renameTitle) }
            catch { model.errorMessage = error.localizedDescription }
          }
          model.destination = nil
        }
        Button("Cancel", role: .cancel) { model.destination = nil }
      }
      .confirmationDialog(
        "Delete this document?", isPresented: Binding(
          get: { model.destination?.is(\.confirmDelete) ?? false },
          set: { if !$0 { model.destination = nil } }
        ), titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if case let .confirmDelete(document) = model.destination {
            do { try model.delete(document.id) }
            catch { model.errorMessage = error.localizedDescription }
          }
          model.destination = nil
        }
        Button("Cancel", role: .cancel) { model.destination = nil }
      }
      .alert("Couldn’t Save Document", isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "Please try again.")
      }
    }
  }
}

private struct TripDocumentEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: TripDocumentsModel
  @State private var title = ""
  @State private var bodyText = ""
  @State private var showingImporter = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        TextField("Title", text: $title)
        Section("Document") {
          TextEditor(text: $bodyText)
            .frame(minHeight: 260)
        }
        Section {
          Button("Import File…", systemImage: "doc.badge.arrow.up") {
            showingImporter = true
          }
        }
      }
      .navigationTitle("Add Document")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try model.add(title: title, body: bodyText)
              model.destination = nil
              dismiss()
            } catch let error as TripDocumentError {
              model.errorMessage = switch error {
              case .emptyBody: "Add some text before saving."
              case .tooLarge: "This document is too large. Keep it under 500 KB."
              }
            } catch {
              model.errorMessage = error.localizedDescription
            }
          }
          .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .fileImporter(
        isPresented: $showingImporter,
        allowedContentTypes: [.plainText, .markdown]
      ) { result in
        do {
          let url = try result.get()
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          bodyText = try String(contentsOf: url, encoding: .utf8)
          title = url.deletingPathExtension().lastPathComponent
        } catch {
          model.errorMessage = error.localizedDescription
        }
      }
      .alert("Can’t Add Document", isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "Please try again.")
      }
    }
  }
}

private struct TripDocumentViewer: View {
  let document: TripDocument

  var body: some View {
    ScrollView {
      Text(renderedBody)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding()
    }
    .navigationTitle(document.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var renderedBody: AttributedString {
    (try? AttributedString(
      markdown: document.body,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(document.body)
  }
}
