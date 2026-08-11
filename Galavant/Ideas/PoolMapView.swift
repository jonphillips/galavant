import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

/// The pool as a map of pins — the visual browsing surface (the "Virginia case").
/// Tapping a pin opens that idea.
struct PoolMapView: View {
  let ideas: [Idea]
  /// The lens regions to frame to (ADR-0013): the active trip's toggled subregions,
  /// or empty to auto-fit the pins.
  var framingRegions: [MapRegion] = []
  /// Ideas already on the active trip — drawn in a distinct tint from candidates
  /// (ADR-0013). Empty for the eternal "All" pool, so nothing reads as "pulled."
  var pulledIDs: Set<Idea.ID> = []
  let onSelect: (Idea) -> Void
  let onSelectMapPlace: (Place) async -> Void
  @Binding var visibleRegion: MKCoordinateRegion?

  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var mapSelection: MapSelection<Idea.ID>?

  private var mappableIdeas: [Idea] {
    ideas.filter { $0.coordinate != nil }
  }

  /// Green = already on this trip, gray = visited, red = a candidate (ADR-0013).
  private func tint(for idea: Idea) -> Color {
    if pulledIDs.contains(idea.id) { return .green }
    return idea.visited ? .gray : .red
  }

  var body: some View {
    Map(position: $cameraPosition, selection: $mapSelection) {
      ForEach(mappableIdeas) { idea in
        if let coordinate = idea.coordinate {
          Marker(
            idea.name,
            systemImage: idea.kind?.systemImage ?? "mappin",
            coordinate: coordinate
          )
          .tint(tint(for: idea))
          .tag(idea.id)
        }
      }
    }
    .onMapCameraChange(frequency: .onEnd) { context in
      visibleRegion = context.region
    }
    .task(id: mapSelection) {
      await handleMapSelection()
    }
    .mapFeatureSelectionAccessory(nil)
    .mapFeatureSelectionDisabled { feature in
      feature.kind != .pointOfInterest
    }
    .onChange(of: framingRegions.map(\.id), initial: true) { frameSelectedRegion() }
    .overlay {
      if mappableIdeas.isEmpty {
        ContentUnavailableView(
          "No pinned ideas",
          systemImage: Icon.map.systemName,
          description: Text("Tap an Apple Maps place to add your first idea.")
        )
        .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .top) {
      MapPlaceSearchOverlay(
        visibleRegion: visibleRegion,
        onSelect: onSelectMapPlace
      )
    }
  }

  private func handleMapSelection() async {
    guard let mapSelection else { return }
    if let id = mapSelection.value {
      if let idea = ideas.first(where: { $0.id == id }) {
        onSelect(idea)
      }
      self.mapSelection = nil
      return
    }
    guard let feature = mapSelection.feature, feature.kind == .pointOfInterest else { return }
    let place = await MapPlaceResolver.place(for: feature)
    guard !Task.isCancelled else { return }
    await onSelectMapPlace(place)
    guard !Task.isCancelled else { return }
    self.mapSelection = nil
  }

  /// Zoom to the union of the lens regions, or auto-frame all pins when unscoped.
  private func frameSelectedRegion() {
    if let box = MapRegion.boundingBox(of: framingRegions) {
      cameraPosition = .region(
        MKCoordinateRegion(
          center: CLLocationCoordinate2D(
            latitude: box.centerLatitude, longitude: box.centerLongitude),
          span: MKCoordinateSpan(
            latitudeDelta: box.latitudeDelta, longitudeDelta: box.longitudeDelta)
        )
      )
    } else {
      cameraPosition = .automatic
    }
  }
}
