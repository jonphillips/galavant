import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

/// Gives a Calendar-originated constraint a real Apple Maps place identity before
/// it is promoted into the itinerary. The sheet owns only transient selection;
/// the caller owns the create-and-link write.
struct AssignConstraintLocationSheet: View {
  private enum InputMode: String, CaseIterable, Identifiable {
    case map
    case search

    var id: Self { self }

    var title: String {
      switch self {
      case .map: "Map"
      case .search: "Search"
      }
    }
  }

  let constraint: CalendarTripConstraint
  let initialRegion: MKCoordinateRegion?
  let onSelectPlace: (Place) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var inputMode: InputMode = .map
  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var mapSelection: MapSelection<UUID>?
  @State private var visibleRegion: MKCoordinateRegion?
  @State private var selectedPlace: Place?
  @State private var showingIdentityWarning = false

  init(
    constraint: CalendarTripConstraint,
    initialRegion: MKCoordinateRegion? = nil,
    onSelectPlace: @escaping (Place) -> Void
  ) {
    self.constraint = constraint
    self.initialRegion = initialRegion
    self.onSelectPlace = onSelectPlace
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Location input", selection: $inputMode) {
          ForEach(InputMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .padding()

        Group {
          switch inputMode {
          case .map:
            PlaceSelectionMap(
              cameraPosition: $cameraPosition,
              selection: $mapSelection,
              visibleRegion: $visibleRegion,
              initialRegion: initialRegion,
              existingPlace: selectedPlace,
              onSelectPlace: { place in
                select(place)
              }
            ) {
              EmptyMapContent()
            }
          case .search:
            NavigationStack {
              FreeformStopLocationSearchView(
                initialQuery: constraint.location ?? constraint.title,
                onSelect: select
              )
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let selectedPlace {
          VStack(alignment: .leading, spacing: 8) {
            Text("Selected place")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(selectedPlace.name)
              .font(.headline)
            if !selectedPlace.subtitle.isEmpty {
              Text(selectedPlace.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Button("Use this place") {
              onSelectPlace(selectedPlace)
              dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .padding()
          .background(.bar)
        }
      }
      .navigationTitle("Give It a Place")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .alert("Apple Maps place required", isPresented: $showingIdentityWarning) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("Choose a named point of interest so Galavant can keep its Apple Maps identity.")
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  private func select(_ place: Place) {
    guard place.mapItemIdentifier != nil else {
      showingIdentityWarning = true
      return
    }
    selectedPlace = place
  }
}
