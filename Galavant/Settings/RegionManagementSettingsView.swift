import GalavantSchema
import MapKit
import SwiftUI
import UIKit

/// The durable map-region administration surface. Regions are geography lenses,
/// so the settings list keeps the selected region's actual map in view instead
/// of asking someone to remember a name-only row from the Ideas screen.
struct RegionManagementSettingsView: View {
  @State private var model = RegionManagementSettingsModel()
  @State private var renaming: MapRegion?
  @State private var name = ""

  var body: some View {
    List(selection: $model.selectedRegionID) {
      ForEach(model.regions) { region in
        NavigationLink(value: region.id) {
          VStack(alignment: .leading, spacing: 3) {
            Text(region.name)
            Text(model.tripUseDescription(for: region))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .contextMenu {
          Button("Rename", systemImage: Icon.edit.systemName) {
            renaming = region
            name = region.name
          }
        }
      }
      .onDelete { model.deleteRegions(at: $0) }
    }
    .navigationTitle("Map Regions")
    .navigationDestination(for: MapRegion.ID.self) { id in
      if let region = model.regions.first(where: { $0.id == id }) {
        RegionMapDetail(
          region: region,
          tripUseDescription: model.tripUseDescription(for: region),
          model: model)
      }
    }
    .overlay {
      if model.regions.isEmpty {
        ContentUnavailableView(
          "No regions",
          systemImage: Icon.map.systemName,
          description: Text("Define a region from the Ideas map, then manage it here.")
        )
      }
    }
    .alert("Rename region", isPresented: Binding(
      get: { renaming != nil },
      set: { if !$0 { renaming = nil } }
    )) {
      TextField("Name", text: $name)
      Button("Save") {
        if let renaming { model.rename(renaming, to: name) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
  }
}

private struct RegionMapDetail: View {
  let region: MapRegion
  let tripUseDescription: String
  let model: RegionManagementSettingsModel

  @State private var showingPhotoPicker = false

  private var thumbnail: Data? {
    model.thumbnail(forRegion: region.id)
  }

  private var camera: MapCameraPosition {
    .region(MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: region.centerLatitude, longitude: region.centerLongitude),
      span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)))
  }

  var body: some View {
    VStack(spacing: 0) {
      Map(initialPosition: camera)
      HStack(spacing: 12) {
        if let thumbnail, let image = UIImage(data: thumbnail) {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
        } else {
          Image(systemName: "photo")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 64)
            .background(.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Region photo")
            .font(.headline)
          Text(tripUseDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(thumbnail == nil ? "Set photo" : "Change photo", systemImage: "photo") {
          showingPhotoPicker = true
        }
        .buttonStyle(.bordered)
      }
      .padding()
      .background(.bar)
    }
    .navigationTitle(region.name)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showingPhotoPicker) {
      RegionPhotoPickerSheet(
        regionID: region.id,
        regionName: region.name,
        hasPhoto: thumbnail != nil)
    }
  }
}
