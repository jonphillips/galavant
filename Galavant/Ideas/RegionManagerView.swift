import GalavantSchema
import SwiftUI

/// Manage saved map regions: rename or delete. (Defining a new region happens
/// from the map view's "Define Region" button.)
struct RegionManagerView: View {
  let model: IdeasListModel
  @Environment(\.dismiss) private var dismiss
  @State private var renaming: MapRegion?
  @State private var newName = ""

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.regions) { region in
          Button {
            renaming = region
            newName = region.name
          } label: {
            HStack {
              Text(region.name).foregroundStyle(.primary)
              Spacer()
              Image(systemName: "pencil").foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { model.deleteRegions(at: $0) }
      }
      .overlay {
        if model.regions.isEmpty {
          ContentUnavailableView(
            "No regions",
            systemImage: "map",
            description: Text("Define a region from the map view's Define Region button.")
          )
        }
      }
      .navigationTitle("Regions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .alert(
        "Rename region",
        isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
      ) {
        TextField("Name", text: $newName)
        Button("Save") {
          if let region = renaming { model.renameRegion(region, to: newName) }
          renaming = nil
        }
        Button("Cancel", role: .cancel) { renaming = nil }
      }
    }
  }
}
