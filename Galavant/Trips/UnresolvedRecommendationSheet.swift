import GalavantPlaces
import GalavantSchema
import SwiftUI

struct UnresolvedRecommendationSheet: View {
  let model: TripPlanningModel
  let stopID: TripIdea.ID
  @Environment(\.dismiss) private var dismiss

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
        } else if let warning = model.recommendationHandoffPaste.warning {
          Section {
            Text(warning)
              .font(.subheadline)
          }
        }
      }
      .navigationTitle("Recommendation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if stop == nil, model.recommendationHandoffPaste.warning != nil {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              model.recommendationHandoffPaste.warning = nil
              model.destination = nil
              dismiss()
            }
          }
        }
      }
      .overlay(alignment: .top) {
        if isSearching {
          MapPlaceSearchOverlay(
            visibleRegion: nil,
            searchRegions: model.tripRegions,
            biased: true,
            seedQuery: stop?.inlineTitle
          ) { place in
            model.recommendationPlaceSelected(stopID: stopID, place: place)
            isSearching = false
          }
          .padding(.top, 8)
        }
      }
    }
  }
}
