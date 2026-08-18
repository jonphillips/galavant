import GalavantPlaces
import MapKit
import SwiftUI

/// A MapKit surface that turns Apple Maps POI taps into the app's `Place` value.
/// Callers may add their own map content, such as pool markers, without taking on
/// the feature-selection and resolution plumbing.
struct PlaceSelectionMap<Content: MapContent>: View {
  @Binding var cameraPosition: MapCameraPosition
  @Binding var mapSelection: MapSelection<UUID>?
  @Binding var visibleRegion: MKCoordinateRegion?

  let initialRegion: MKCoordinateRegion?
  let existingPlace: Place?
  let onSelectPlace: (Place) async -> Void
  let onSelectValue: ((UUID) -> Void)?
  let mapContent: () -> Content

  init(
    cameraPosition: Binding<MapCameraPosition>,
    selection: Binding<MapSelection<UUID>?>,
    visibleRegion: Binding<MKCoordinateRegion?> = .constant(nil),
    initialRegion: MKCoordinateRegion? = nil,
    existingPlace: Place? = nil,
    onSelectPlace: @escaping (Place) async -> Void,
    onSelectValue: ((UUID) -> Void)? = nil,
    @MapContentBuilder mapContent: @escaping () -> Content
  ) {
    self._cameraPosition = cameraPosition
    self._mapSelection = selection
    self._visibleRegion = visibleRegion
    self.initialRegion = initialRegion
    self.existingPlace = existingPlace
    self.onSelectPlace = onSelectPlace
    self.onSelectValue = onSelectValue
    self.mapContent = mapContent
  }

  var body: some View {
    Map(position: $cameraPosition, selection: $mapSelection) {
      mapContent()
      if let existingPlace {
        Marker(
          existingPlace.name,
          systemImage: "mappin.and.ellipse",
          coordinate: CLLocationCoordinate2D(
            latitude: existingPlace.latitude,
            longitude: existingPlace.longitude
          )
        )
      }
    }
    .task(id: mapSelection) {
      await handleMapSelection()
    }
    .mapFeatureSelectionAccessory(nil)
    .mapFeatureSelectionDisabled { feature in
      feature.kind != .pointOfInterest
    }
    .onMapCameraChange(frequency: .onEnd) { context in
      visibleRegion = context.region
    }
    .onAppear {
      if let initialRegion {
        cameraPosition = .region(initialRegion)
      }
    }
  }

  private func handleMapSelection() async {
    guard let mapSelection else { return }

    if let id = mapSelection.value {
      onSelectValue?(id)
      self.mapSelection = nil
      return
    }

    guard let feature = mapSelection.feature, feature.kind == .pointOfInterest else { return }
    let place = await MapPlaceResolver.place(for: feature)
    guard !Task.isCancelled else { return }
    await onSelectPlace(place)
    guard !Task.isCancelled else { return }
    self.mapSelection = nil
  }
}
