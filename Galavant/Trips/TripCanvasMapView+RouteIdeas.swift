import CoreLocation
import GalavantSchema
import MapKit
import SwiftUI

extension TripCanvasMapView {
  /// Unnumbered idea pins appear only on the selected day's lens. They have no
  /// map selection tag because their IDs are pool ideas, not itinerary stops.
  @MapContentBuilder
  var routeIdeasContent: some MapContent {
    if showsIdeasAlongRoute,
      model.canvasSelectedStayID == nil,
      let day = model.canvasSelectedDay
    {
      ForEach(model.ideasAlongRoute(forDay: day)) { pin in
        let idea = pin.idea
        Annotation(
          idea.name,
          coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        ) {
          Button {
            model.showRouteIdeaDetail(idea, day: day)
          } label: {
            RouteIdeaPin(systemImage: idea.kind?.systemImage ?? "mappin", isOnTrip: pin.isOnTrip)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Show details for \(idea.name)")
        }
      }
    }
  }
}

private struct RouteIdeaPin: View {
  let systemImage: String
  let isOnTrip: Bool

  private var color: Color { isOnTrip ? .green : .gray }

  var body: some View {
    Image(systemName: systemImage)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .frame(width: 28, height: 28)
      .background(.background, in: Circle())
      .overlay { Circle().stroke(color, lineWidth: 2) }
      .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
  }
}
