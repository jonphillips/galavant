import CoreLocation
import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

/// A small map editor for a freeform stop. Tapping the map drops a pin; dragging
/// the pin refines it. The map uses MapKit only at this app-layer boundary, while
/// named-place lookup below goes through the injectable PlaceSearchModel.
struct FreeformStopLocationMap: View {
  private struct MapCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
      latitude = coordinate.latitude
      longitude = coordinate.longitude
    }

    var location: CLLocationCoordinate2D {
      CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
  }

  @Binding var coordinate: CLLocationCoordinate2D?
  let title: String
  let fallbackRegion: MKCoordinateRegion?

  @State private var cameraPosition: MapCameraPosition
  @State private var isDragging = false

  init(
    coordinate: Binding<CLLocationCoordinate2D?>,
    title: String,
    fallbackRegion: MKCoordinateRegion?
  ) {
    _coordinate = coordinate
    self.title = title
    self.fallbackRegion = fallbackRegion
    _cameraPosition = State(initialValue: .automatic)
  }

  var body: some View {
    MapReader { proxy in
      Map(position: $cameraPosition) {
        if let coordinate {
          Annotation(
            title.isEmpty ? "Custom stop" : title,
            coordinate: coordinate,
            anchor: .bottom
          ) {
            Image(systemName: "mappin.and.ellipse")
              .font(.title2)
              .foregroundStyle(.red)
              .shadow(radius: 2)
              .contentShape(Rectangle())
              .gesture(
                DragGesture(coordinateSpace: .named("freeform-stop-map"))
                  .onChanged { value in
                    isDragging = true
                    if let location = proxy.convert(
                      value.location, from: .named("freeform-stop-map")) {
                      self.coordinate = location
                    }
                  }
                  .onEnded { _ in
                    isDragging = false
                  })
              .accessibilityLabel("Custom stop location")
              .accessibilityHint("Drag to adjust the pin")
          }
        }
      }
      .coordinateSpace(name: "freeform-stop-map")
      .simultaneousGesture(
        SpatialTapGesture().onEnded { value in
          guard coordinate == nil else { return }
          if let location = proxy.convert(
            value.location, from: .named("freeform-stop-map")) {
            coordinate = location
          }
        })
      .onChange(of: coordinate.map { MapCoordinate($0) }) { _, newValue in
        guard !isDragging, let newValue else { return }
        cameraPosition = .region(Self.region(around: newValue.location))
      }
      .onAppear {
        if coordinate == nil, let fallbackRegion {
          cameraPosition = .region(fallbackRegion)
        } else if let coordinate {
          cameraPosition = .region(Self.region(around: coordinate))
        }
      }
    }
    .overlay(alignment: .bottomLeading) {
      Text(coordinate == nil ? "Tap the map to place this stop" : "Drag the pin to adjust")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
        .allowsHitTesting(false)
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
    MKCoordinateRegion(
      center: coordinate,
      span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
  }
}

struct FreeformStopLocationSearchView: View {
  let onSelect: (Place) -> Void
  @State private var search = PlaceSearchModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var search = search
    List(search.results) { place in
      Button {
        onSelect(place)
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
        ContentUnavailableView(
          search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Search for a place" : "No places found",
          systemImage: "mappin.and.ellipse",
          description: Text("Choose a Maps result to place this custom stop."))
      }
    }
  }
}

extension Array where Element == (latitude: Double, longitude: Double) {
  var mapRegion: MKCoordinateRegion? {
    guard let box = MapFraming.box(for: self) else { return nil }
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: box.centerLatitude, longitude: box.centerLongitude),
      span: MKCoordinateSpan(
        latitudeDelta: box.latitudeDelta, longitudeDelta: box.longitudeDelta))
  }
}
