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
  var placeSelectionPolicy: PlaceSelectionPresentationPolicy = .immediate
  var selectedIdeaID: Idea.ID? = nil
  let onSelect: (Idea) -> Void
  let onSelectMapPlace: (Place) async -> Void
  @Binding var visibleRegion: MKCoordinateRegion?

  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var mapSelection: MapSelection<Idea.ID>?
  @State private var selectedMapItem: MKMapItem?

  private var mappableIdeas: [Idea] {
    ideas.filter { $0.coordinate != nil }
  }

  /// Green = already on this trip, gray = visited, red = a candidate (ADR-0013).
  private func tint(for idea: Idea) -> Color {
    if pulledIDs.contains(idea.id) { return .green }
    return idea.visited ? .gray : .red
  }

  var body: some View {
    VStack(spacing: 0) {
      // This must be a real sibling above Map, not an overlay: Xcode 27 beta's
      // Map gesture surface steals taps from overlaid SwiftUI Buttons.
      if case .exploreFirst = placeSelectionPolicy, let selectedMapItem {
        HStack {
          Spacer()
          MapPlaceCreateIdeaButton(
            mapItem: selectedMapItem,
            onCreate: { @MainActor mapItem in await createIdea(for: mapItem) }
          )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
      }
      PlaceSelectionMap(
        cameraPosition: $cameraPosition,
        selection: $mapSelection,
        visibleRegion: $visibleRegion,
        selectedMapItem: $selectedMapItem,
        presentationPolicy: placeSelectionPolicy,
        onSelectPlace: onSelectMapPlace,
        onSelectValue: { id in
          if let idea = ideas.first(where: { $0.id == id }) {
            onSelect(idea)
          }
        }
      ) {
        ForEach(mappableIdeas) { idea in
          if idea.id != selectedIdeaID, let coordinate = idea.coordinate {
            Marker(
              idea.name,
              systemImage: idea.kind?.systemImage ?? "mappin",
              coordinate: coordinate
            )
            .tint(tint(for: idea))
            .tag(idea.id)
          }
        }
        if let idea = mappableIdeas.first(where: { $0.id == selectedIdeaID }),
           let coordinate = idea.coordinate {
          Annotation(idea.name, coordinate: coordinate, anchor: .bottom) {
            Button { onSelect(idea) } label: {
              VStack(spacing: -5) {
                Image(systemName: idea.kind?.systemImage ?? "mappin")
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(.white)
                  .frame(width: 34, height: 34)
                  .background(Color.accentColor, in: Circle())
                  .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: "triangle.fill")
                  .font(.system(size: 10))
                  .rotationEffect(.degrees(180))
                  .foregroundStyle(Color.accentColor)
              }
              .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          .annotationTitles(.hidden)
        }
      }
      .onChange(of: framingRegions.map(\.id), initial: true) { frameSelectedRegion() }
      .onChange(of: selectedIdeaID) { _, ideaID in focusIdea(ideaID) }
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
  }

  private func createIdea(for mapItem: MKMapItem) async {
    // Let the native detail presentation unwind before the app presents its own
    // capture sheet. The retained item remains the source for the capture draft.
    selectedMapItem = nil
    await Task.yield()
    await onSelectMapPlace(Place(mapItem: mapItem))
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

  private func focusIdea(_ ideaID: Idea.ID?) {
    guard let ideaID,
          let coordinate = mappableIdeas.first(where: { $0.id == ideaID })?.coordinate else { return }
    guard let region = visibleRegion ?? cameraPosition.region else { return }
    let latitudeIsVisible = abs(coordinate.latitude - region.center.latitude) <= region.span.latitudeDelta / 2
    let longitudeIsVisible = abs(coordinate.longitude - region.center.longitude) <= region.span.longitudeDelta / 2
    guard !latitudeIsVisible || !longitudeIsVisible else { return }
    cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: region.span))
  }
}
