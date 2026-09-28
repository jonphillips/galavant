import GalavantPlaces
import GalavantSchema
import SwiftUI

struct UnresolvedRecommendationSheet: View {
  let model: TripPlanningModel
  let stopID: TripIdea.ID

  @State private var isSearching = false

  private var stop: TripIdea? {
    model.allTripIdeas.first { $0.id == stopID }
  }

  var body: some View {
    NavigationStack {
      List {
        if let stop {
          Section {
            Text(stop.inlineTitle ?? "Untitled recommendation")
              .font(.headline)
            if let note = stop.inlineNote, !note.isEmpty {
              Text(note)
                .textSelection(.enabled)
            }
          }

          Section {
            Button {
              isSearching = true
            } label: {
              Label("Find on Map", systemImage: "magnifyingglass")
            }
            Button(role: .destructive) {
              model.remove(stopID)
              model.destination = nil
            } label: {
              Label("Remove", systemImage: "trash")
            }
          }
        }
      }
      .navigationTitle("Recommendation")
      .navigationBarTitleDisplayMode(.inline)
      .overlay(alignment: .top) {
        if isSearching {
          MapPlaceSearchOverlay(
            visibleRegion: nil,
            searchRegions: model.tripRegions,
            biased: true
          ) { place in
            model.recommendationPlaceSelected(stopID: stopID, place: place)
          }
          .padding(.top, 8)
        }
      }
      .alert(
        "Already on your trip",
        isPresented: Binding(
          get: { model.pendingRecommendationReconcile != nil },
          set: { if !$0 { model.pendingRecommendationReconcile = nil } }
        )
      ) {
        Button("Merge") { model.recommendationReconcileChoice(.merge) }
          .keyboardShortcut(.defaultAction)
        Button("Keep Both", role: .cancel) {
          model.recommendationReconcileChoice(.keepBoth)
        }
      } message: {
        if let collision = model.pendingRecommendationReconcile {
          Text("This place is already \(collision.existingStatus.label.lowercased()) in this trip. Merge the two rationales, or keep both rows?")
        }
      }
    }
  }
}
