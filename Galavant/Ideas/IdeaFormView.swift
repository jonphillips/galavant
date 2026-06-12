import Dependencies
import GalavantSchema
import MapKit
import SQLiteData
import SwiftUI

struct IdeaFormView: View {
  @State var draft: Idea.Draft
  @State private var search = LocationSearchModel()
  @Environment(\.dismiss) private var dismiss
  @Dependency(\.defaultDatabase) private var database

  private var hasLocation: Bool {
    draft.latitude != nil && draft.longitude != nil
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $draft.name)
        Picker("Kind", selection: $draft.kind) {
          Text("Unspecified").tag(IdeaKind?.none)
          ForEach(IdeaKind.allCases, id: \.self) { kind in
            Label(kind.label, systemImage: kind.systemImage).tag(IdeaKind?.some(kind))
          }
        }

        Section("Location") {
          if hasLocation {
            HStack {
              Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.red)
              VStack(alignment: .leading) {
                Text(draft.name.isEmpty ? "Pinned location" : draft.name)
                if let regionName = draft.regionName, !regionName.isEmpty {
                  Text(regionName).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Clear", role: .destructive) { clearLocation() }
                .buttonStyle(.borderless)
            }
          } else {
            TextField("Search a place", text: $search.query)
              .textInputAutocapitalization(.words)
            ForEach(search.results, id: \.self) { completion in
              Button {
                Task { await pickPlace(completion) }
              } label: {
                VStack(alignment: .leading) {
                  Text(completion.title).foregroundStyle(.primary)
                  if !completion.subtitle.isEmpty {
                    Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }

        TextField("Link", text: $draft.url)
          .textContentType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Toggle("Visited", isOn: $draft.visited)
        Section("Notes") {
          TextEditor(text: $draft.notes)
            .frame(minHeight: 120)
        }
      }
      .navigationTitle(draft.id == nil ? "New Idea" : "Edit Idea")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { saveButtonTapped() }
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func pickPlace(_ completion: MKLocalSearchCompletion) async {
    guard let place = await search.resolve(completion) else { return }
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
      draft.name = place.name
    }
    draft.latitude = place.latitude
    draft.longitude = place.longitude
    draft.regionName = place.regionName
    search.query = ""
  }

  private func clearLocation() {
    draft.latitude = nil
    draft.longitude = nil
  }

  private func saveButtonTapped() {
    withErrorReporting {
      try database.write { db in
        var draft = draft
        draft.travelPartyID = try TravelParty.ensureDefault(in: db).id
        try Idea.upsert { draft }.execute(db)
      }
    }
    dismiss()
  }
}
