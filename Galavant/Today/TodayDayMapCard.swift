import GalavantSchema
import MapKit
import SwiftUI

/// A static, glanceable route map for the day Today is showing. Its inputs are
/// the already-resolved day values; it never asks the planning model for a plan.
struct TodayDayMapCard: View {
  let day: Int
  let stops: [ResolvedStop]
  let route: [TravelEndpoint]
  let baseStays: [ResolvedStay]
  let nextEndpointID: String?
  let settledStopIDs: Set<UUID>
  let isLiveDay: Bool
  let onSelectIdea: (Idea) -> Void

  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var deviceLocation = DeviceLocationModel()

  private var dayPoints: [(latitude: Double, longitude: Double)] {
    stops.compactMap { stop in
      guard let coordinate = stop.coordinate else { return nil }
      return (latitude: coordinate.latitude, longitude: coordinate.longitude)
    } + baseStays.compactMap { stay in
      guard let latitude = stay.content.latitude, let longitude = stay.content.longitude else {
        return nil
      }
      return (latitude: latitude, longitude: longitude)
    }
  }

  private var shouldFollowDevice: Bool {
    isLiveDay && deviceLocation.state == .tracking
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("DAY \(day) MAP")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .tracking(1.1)

      Map(position: $cameraPosition, interactionModes: []) {
        routeContent
        stopContent
        stayContent
        if deviceLocation.state == .tracking {
          UserAnnotation()
        }
      }
      .frame(height: 240)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(alignment: .topTrailing) {
        locationControl
          .padding(10)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .onAppear {
      deviceLocation.refresh()
      frameCamera()
    }
    .onChange(of: day) { _, _ in frameCamera() }
    .onChange(of: deviceLocation.coordinate) { oldCoordinate, newCoordinate in
      guard isLiveDay, oldCoordinate == nil, let newCoordinate else { return }
      frameCamera(including: newCoordinate)
    }
    .task(id: shouldFollowDevice) {
      guard shouldFollowDevice else { return }
      await deviceLocation.followCoordinate()
    }
  }

  @MapContentBuilder
  private var routeContent: some MapContent {
    let coordinates = route.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    if coordinates.count >= 2 {
      MapPolyline(coordinates: coordinates)
        .stroke(DayPalette.color(forDay: day), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
  }

  @MapContentBuilder
  private var stopContent: some MapContent {
    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
      if let coordinate = stop.coordinate {
        Annotation(stop.content.title, coordinate: CLLocationCoordinate2D(
          latitude: coordinate.latitude,
          longitude: coordinate.longitude), anchor: .bottom) {
            stopPin(stop, number: index + 1)
              .opacity(settledStopIDs.contains(stop.id) ? 0.4 : 1)
          }
      }
    }
  }

  @ViewBuilder
  private func stopPin(_ stop: ResolvedStop, number: Int) -> some View {
    let pin = SequencePin(
      number: number,
      color: DayPalette.color(forDay: day),
      selected: stop.travelEndpointID == nextEndpointID)
    if let idea = stop.idea {
      Button { onSelectIdea(idea) } label: { pin }
        .buttonStyle(.plain)
    } else {
      pin
    }
  }

  @MapContentBuilder
  private var stayContent: some MapContent {
    ForEach(baseStays) { stay in
      if let latitude = stay.content.latitude, let longitude = stay.content.longitude {
        Annotation(stay.content.title, coordinate: CLLocationCoordinate2D(
          latitude: latitude,
          longitude: longitude), anchor: .bottom) {
            let pin = BasePin(selected: stay.travelEndpointID == nextEndpointID)
            if let idea = stay.idea {
              Button { onSelectIdea(idea) } label: { pin }
                .buttonStyle(.plain)
            } else {
              pin
            }
          }
      }
    }
  }

  @ViewBuilder
  private var locationControl: some View {
    switch deviceLocation.state {
    case .offered, .asking:
      Button {
        Task { await deviceLocation.locationButtonTapped() }
      } label: {
        Image(systemName: "location")
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .disabled(deviceLocation.state == .asking)
      .accessibilityLabel("Show my location")
    case .tracking, .withheld:
      EmptyView()
    }
  }

  private func frameCamera(including coordinate: DeviceCoordinate? = nil) {
    let device = isLiveDay ? coordinate.map { (latitude: $0.latitude, longitude: $0.longitude) } : nil
    guard let box = MapFraming.box(for: dayPoints, including: device) else { return }
    cameraPosition = .region(MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: box.centerLatitude,
        longitude: box.centerLongitude),
      span: MKCoordinateSpan(
        latitudeDelta: box.latitudeDelta,
        longitudeDelta: box.longitudeDelta)))
  }
}
