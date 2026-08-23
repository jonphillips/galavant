import Foundation
import GalavantSchema
import MapKit
import SwiftUI

struct RecommendationWorkspaceMap: View {
  let model: RecommendationWorkspaceModel
  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var mapSelection: MapSelection<UUID>?
  @State private var visibleRegion: MKCoordinateRegion?
  @State private var didInitialFrame = false

  var body: some View {
    PlaceSelectionMap(
      cameraPosition: $cameraPosition,
      selection: $mapSelection,
      visibleRegion: $visibleRegion,
      presentationPolicy: .immediate,
      onSelectPlace: { place in model.resolveResultTapped(place) }
    ) {
      ForEach(model.itineraryMarkers) { marker in
        Marker(marker.title, systemImage: "mappin", coordinate: coordinate(marker.latitude, marker.longitude))
          .tint(.blue)
      }
      ForEach(model.candidateMarkers) { marker in
        if isActiveMarker(marker.state) {
          // The focused candidate is the subject of "Use This Place" — draw it as a
          // large ringed pin so it's unmistakable which location that button acts on.
          Annotation(marker.title, coordinate: coordinate(marker.latitude, marker.longitude)) {
            activeCandidatePin(marker.state)
          }
        } else {
          Marker(
            marker.title,
            systemImage: markerSymbol(marker.state),
            coordinate: coordinate(marker.latitude, marker.longitude)
          )
          .tint(markerColor(marker.state))
        }
      }
      ForEach(model.resolveResults) { place in
        // Confirmable matches — big labeled pins so you can see exactly what
        // "Use This Place" will pick before committing to one.
        Annotation(place.name, coordinate: coordinate(place.latitude, place.longitude)) {
          resolveResultPin
        }
      }
    }
    // Search the map to jump straight to a place. Picking a match resolves the
    // focused candidate to it directly (no second "Use This Place" tap); the button
    // stays for the manual "pan, tap a POI, confirm" path.
    .overlay(alignment: .top) {
      MapPlaceSearchOverlay(
        visibleRegion: visibleRegion,
        // Bias the search toward where the candidate/trip actually is, not the camera
        // box — otherwise a resolve zoom pinholes it and the next candidate finds nothing.
        searchRegions: model.candidateSearchRegions,
        biased: true,
        // Don't prefill for an already-mapped candidate — the auto-search just
        // litters the map with matches over a place that's already pinned.
        seedQuery: model.activeCandidate.flatMap { $0.isResolved ? nil : $0.title }
      ) { place in
        cameraPosition = .region(
          MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
          )
        )
        model.resolveResultTapped(place)
      }
    }
    // Frame the set once, on load. After that the camera stays put through resolves
    // and searches, so a freshly mapped pin doesn't get yanked out from under you.
    .onChange(of: model.mapViewport, initial: true) { _, viewport in
      guard !didInitialFrame, let viewport else { return }
      cameraPosition = .region(
        MKCoordinateRegion(
          center: CLLocationCoordinate2D(
            latitude: viewport.centerLatitude,
            longitude: viewport.centerLongitude
          ),
          span: MKCoordinateSpan(
            latitudeDelta: viewport.latitudeDelta,
            longitudeDelta: viewport.longitudeDelta
          )
        )
      )
      didInitialFrame = true
    }
    // Switching candidates pans to keep the focused pin in view for relative context —
    // but only expands the current frame when the pin is off-screen, so it never yanks
    // a pin that's already visible and never zooms tight onto it.
    .onChange(of: model.effectiveActiveCandidateID) { _, _ in
      guard let location = model.activeCandidateLocation else { return }
      let target = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
      guard let current = visibleRegion else {
        withAnimation {
          cameraPosition = .region(
            MKCoordinateRegion(center: target, span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
          )
        }
        return
      }
      guard !region(current, contains: target) else { return }
      withAnimation { cameraPosition = .region(region(current, including: target)) }
    }
  }

  private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private func region(_ region: MKCoordinateRegion, contains coordinate: CLLocationCoordinate2D) -> Bool {
    abs(coordinate.latitude - region.center.latitude) <= region.span.latitudeDelta / 2
      && abs(coordinate.longitude - region.center.longitude) <= region.span.longitudeDelta / 2
  }

  /// The smallest region covering `region` plus `coordinate`, with a little margin so
  /// the newly included pin isn't jammed against the edge.
  private func region(_ region: MKCoordinateRegion, including coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
    let minLatitude = min(region.center.latitude - region.span.latitudeDelta / 2, coordinate.latitude)
    let maxLatitude = max(region.center.latitude + region.span.latitudeDelta / 2, coordinate.latitude)
    let minLongitude = min(region.center.longitude - region.span.longitudeDelta / 2, coordinate.longitude)
    let maxLongitude = max(region.center.longitude + region.span.longitudeDelta / 2, coordinate.longitude)
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: (minLatitude + maxLatitude) / 2,
        longitude: (minLongitude + maxLongitude) / 2
      ),
      span: MKCoordinateSpan(
        latitudeDelta: (maxLatitude - minLatitude) * 1.3,
        longitudeDelta: (maxLongitude - minLongitude) * 1.3
      )
    )
  }

  private func isActiveMarker(_ state: CandidateMapMarkerState) -> Bool {
    switch state {
    case let .fuzzy(isActive), let .resolved(isActive): isActive
    }
  }

  @ViewBuilder private func activeCandidatePin(_ state: CandidateMapMarkerState) -> some View {
    let resolved = if case .resolved = state { true } else { false }
    ZStack {
      Circle()
        .fill((resolved ? Color.green : Color.orange).opacity(0.28))
        .frame(width: 48, height: 48)
      Image(systemName: resolved ? "mappin.circle.fill" : "sparkles")
        .font(.title)
        .foregroundStyle(resolved ? Color.green : Color.orange)
    }
    .shadow(radius: 3)
  }

  private var resolveResultPin: some View {
    Image(systemName: "mappin.circle.fill")
      .font(.largeTitle)
      .foregroundStyle(.purple)
      .background(Circle().fill(.white).padding(4))
      .shadow(radius: 3)
  }

  private func markerSymbol(_ state: CandidateMapMarkerState) -> String {
    switch state {
    case .fuzzy: "sparkles"
    case .resolved: "mappin.circle.fill"
    }
  }

  private func markerColor(_ state: CandidateMapMarkerState) -> Color {
    switch state {
    // Resolved (mapped) candidates stay green whether or not they're the focused
    // one, so the whole set's confirmed geography accumulates on the map. The
    // focused candidate is orange; unmapped fuzzy guesses are muted grey.
    case let .fuzzy(isActive): isActive ? .orange : .gray
    case let .resolved(isActive): isActive ? .orange : .green
    }
  }
}
