import GalavantSchema
import MapKit
import SwiftUI

/// The pool as a map of pins — the visual browsing surface (the "Virginia case").
/// Tapping a pin opens that idea.
struct PoolMapView: View {
  let ideas: [Idea]
  let onSelect: (Idea) -> Void
  @Binding var visibleRegion: MKCoordinateRegion?

  @State private var selectedIdeaID: Idea.ID?

  private var mappableIdeas: [Idea] {
    ideas.filter { $0.coordinate != nil }
  }

  var body: some View {
    Map(selection: $selectedIdeaID) {
      ForEach(mappableIdeas) { idea in
        if let coordinate = idea.coordinate {
          Marker(
            idea.name,
            systemImage: idea.kind?.systemImage ?? "mappin",
            coordinate: coordinate
          )
          .tint(idea.visited ? .gray : .red)
          .tag(idea.id)
        }
      }
    }
    .onMapCameraChange(frequency: .onEnd) { context in
      visibleRegion = context.region
    }
    .overlay {
      if mappableIdeas.isEmpty {
        ContentUnavailableView(
          "No pinned ideas",
          systemImage: "map",
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
}
