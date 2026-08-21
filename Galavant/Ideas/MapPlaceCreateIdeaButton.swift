import MapKit
import SwiftUI

/// Galavant's action that sits beside Apple's closed native place detail.
struct MapPlaceCreateIdeaButton: View {
  let mapItem: MKMapItem
  let onCreate: @MainActor (MKMapItem) async -> Void

  var body: some View {
    Button {
      Task { @MainActor in await onCreate(mapItem) }
    } label: {
      Label("Create Idea", systemImage: "plus")
    }
    .buttonStyle(.borderedProminent)
    .accessibilityHint("Opens the prefilled Create Idea form for this place.")
  }
}
