import GalavantPlaces
import MapKit
import SwiftUI

enum PlaceSelectionPresentationPolicy: Equatable {
  case immediate
  case exploreFirst(DetailPresentation)

  enum DetailPresentation: Equatable {
    case sheet
    case popover
  }
}

/// A MapKit surface that resolves Apple Maps POI taps for either immediate capture
/// or read-only native detail exploration. Callers may add their own map content,
/// such as pool markers, without taking on the feature-selection plumbing.
struct PlaceSelectionMap<Content: MapContent>: View {
  @Binding var cameraPosition: MapCameraPosition
  @Binding var mapSelection: MapSelection<UUID>?
  @Binding var visibleRegion: MKCoordinateRegion?
  @Binding var selectedMapItem: MKMapItem?

  let initialRegion: MKCoordinateRegion?
  let existingPlace: Place?
  let presentationPolicy: PlaceSelectionPresentationPolicy
  let onSelectPlace: (Place) async -> Void
  let onSelectValue: ((UUID) -> Void)?
  let mapContent: () -> Content

  init(
    cameraPosition: Binding<MapCameraPosition>,
    selection: Binding<MapSelection<UUID>?>,
    visibleRegion: Binding<MKCoordinateRegion?> = .constant(nil),
    initialRegion: MKCoordinateRegion? = nil,
    existingPlace: Place? = nil,
    selectedMapItem: Binding<MKMapItem?> = .constant(nil),
    presentationPolicy: PlaceSelectionPresentationPolicy = .immediate,
    onSelectPlace: @escaping (Place) async -> Void,
    onSelectValue: ((UUID) -> Void)? = nil,
    @MapContentBuilder mapContent: @escaping () -> Content
  ) {
    self._cameraPosition = cameraPosition
    self._mapSelection = selection
    self._visibleRegion = visibleRegion
    self._selectedMapItem = selectedMapItem
    self.initialRegion = initialRegion
    self.existingPlace = existingPlace
    self.presentationPolicy = presentationPolicy
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
    .modifier(MapFeatureSelectionAccessoryModifier())
    .modifier(MapFeatureSelectionDisabledModifier())
    .modifier(
      MapItemDetailPresentationModifier(
        item: $selectedMapItem,
        policy: presentationPolicy
      )
    )
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
    switch presentationPolicy {
    case .immediate:
      let place = await MapPlaceResolver.place(for: feature)
      guard !Task.isCancelled else { return }
      await onSelectPlace(place)
    case .exploreFirst:
      guard let mapItem = await MapPlaceResolver.mapItem(for: feature) else {
        self.mapSelection = nil
        return
      }
      guard !Task.isCancelled else { return }
      selectedMapItem = mapItem
    }
    guard !Task.isCancelled else { return }
    self.mapSelection = nil
  }
}

private struct MapFeatureSelectionAccessoryModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content.mapFeatureSelectionAccessory(nil)
    } else {
      content
    }
  }
}

private struct MapFeatureSelectionDisabledModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.mapFeatureSelectionDisabled { feature in
        feature.kind != .pointOfInterest
      }
    } else {
      content
    }
  }
}

private struct MapItemDetailPresentationModifier: ViewModifier {
  @Binding var item: MKMapItem?
  let policy: PlaceSelectionPresentationPolicy

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      switch policy {
      case .immediate:
        content
      case .exploreFirst(.sheet):
        content.mapItemDetailSheet(item: $item)
      case .exploreFirst(.popover):
        content.mapItemDetailPopover(
          item: $item,
          attachmentAnchor: .rect(.bounds),
          arrowEdge: .leading
        )
      }
    } else {
      content
    }
  }
}
