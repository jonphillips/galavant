import GalavantPlaces
import SwiftUI

/// Correct (or supply) a captured place's location from the confirm sheet. The
/// automatic Apple Maps match is a best-effort guess — it can land on a junk hit
/// or, for pages with only a bare name (koancph.dk), come up empty — so the user
/// needs a way to search and pick the right place. Reuses the package's debounced
/// `PlaceSearchModel`/`PlaceSearchClient`; tapping a result applies it to the
/// capture draft and pops back.
struct LocationSearchView: View {
  @Bindable var model: CaptureModel
  @State private var search = PlaceSearchModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List(search.results) { place in
      Button {
        model.useLocation(place)
        dismiss()
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(place.name)
          if !place.subtitle.isEmpty {
            Text(place.subtitle)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .buttonStyle(.plain)
    }
    .navigationTitle("Location")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search.query, prompt: "Search for the place")
    .overlay {
      if search.results.isEmpty {
        if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView(
            "Search for a place", systemImage: "mappin.and.ellipse",
            description: Text("Find the place on Apple Maps to set its location.")
          )
        } else {
          ContentUnavailableView.search(text: search.query)
        }
      }
    }
  }
}
