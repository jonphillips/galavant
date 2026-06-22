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
  @Binding var visibleRegion: MKCoordinateRegion?

  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var selectedIdeaID: Idea.ID?

  private var mappableIdeas: [Idea] {
    ideas.filter { $0.coordinate != nil }
  }

  /// Green = already on this trip, gray = visited, red = a candidate (ADR-0013).
  private func tint(for idea: Idea) -> Color {
    if pulledIDs.contains(idea.id) { return .green }
    return idea.visited ? .gray : .red
  }

  var body: some View {
    Map(position: $cameraPosition, selection: $selectedIdeaID) {
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
    .onChange(of: framingRegions.map(\.id), initial: true) { frameSelectedRegion() }
    .overlay {
      if mappableIdeas.isEmpty {
        ContentUnavailableView(
          "No pinned ideas",
          systemImage: Icon.map.systemName,
          description: Text("Add a location to an idea to see it on the map.")
        )
      }
    }
    .onChange(of: selectedIdeaID) { _, newValue in
      guard let id = newValue, let idea = ideas.first(where: { $0.id == id }) else { return }
      onSelect(idea)
      selectedIdeaID = nil
    }
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
