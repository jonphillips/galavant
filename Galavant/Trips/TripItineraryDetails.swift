import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

struct CalendarConstraintDetailSheet: View {
  let constraint: CalendarTripConstraint
  let model: TripPlanningModel
  let reconciliationModel: CalendarReconciliationModel
  @Environment(\.dismiss) private var dismiss
  @State private var showingLocationPicker = false

  var body: some View {
    NavigationStack {
      List {
        Section("Calendar event") {
          LabeledContent("Title", value: constraint.title)
          if let displayTime = constraint.displayTime {
            LabeledContent("Time", value: displayTime)
          }
          if let location = constraint.location {
            LabeledContent("Location", value: location)
          }
        }
        if let notes = constraint.notes {
          Section("Notes") {
            Text(notes)
              .textSelection(.enabled)
          }
        }
        Section {
          Button("Give this a place") {
            showingLocationPicker = true
          }
          .buttonStyle(.borderedProminent)
        } footer: {
          Text("The event's Calendar time will stay attached to the new itinerary stop.")
        }
      }
      .navigationTitle("Calendar Event")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(isPresented: $showingLocationPicker) {
        AssignConstraintLocationSheet(
          constraint: constraint,
          initialRegion: dayRegion
        ) { place in
          Task { await placeChosen(place) }
        }
      }
    }
  }

  private var dayRegion: MKCoordinateRegion? {
    guard let region = model.plan.region(forDay: constraint.dayNumber) else { return nil }
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: region.centerLatitude,
        longitude: region.centerLongitude),
      span: MKCoordinateSpan(
        latitudeDelta: region.latitudeDelta,
        longitudeDelta: region.longitudeDelta))
  }

  private func placeChosen(_ place: Place) async {
    guard let trip = model.trip else { return }
    await reconciliationModel.promote(
      constraint: constraint,
      place: place,
      trip: trip,
      plan: model.plan)
    guard case .failure = reconciliationModel.state else {
      dismiss()
      return
    }
  }
}

/// Hands off to Apple Maps with the connector's from→to pair and chosen mode.
/// Kept as the single Maps-launch path for itinerary and Today surfaces.
func openInMaps(connector: TravelConnector) {
  let source = MKMapItem(
    location: CLLocation(latitude: connector.from.latitude, longitude: connector.from.longitude),
    address: nil)
  source.name = connector.from.title
  let dest = MKMapItem(
    location: CLLocation(latitude: connector.to.latitude, longitude: connector.to.longitude),
    address: nil)
  dest.name = connector.to.title
  MKMapItem.openMaps(with: [source, dest], launchOptions: [
    MKLaunchOptionsDirectionsModeKey: connector.mode.mkDirectionsMode
  ])
}

/// Hands off to Apple Maps from the user's current location when no prior
/// itinerary location is available for the next stop.
func openInMaps(fromCurrentLocationTo endpoint: TravelEndpoint, mode: TransportMode) {
  let destination = MKMapItem(
    location: CLLocation(latitude: endpoint.latitude, longitude: endpoint.longitude),
    address: nil)
  destination.name = endpoint.title
  MKMapItem.openMaps(with: [MKMapItem.forCurrentLocation(), destination], launchOptions: [
    MKLaunchOptionsDirectionsModeKey: mode.mkDirectionsMode
  ])
}

func isLooseAlternativeSlot(_ schedule: Schedule) -> Bool {
  switch schedule {
  case .day, .unscheduled: true
  case .daypart, .timed: false
  }
}

func constraintTime(_ constraint: CalendarTripConstraint) -> String {
  guard let start = constraint.startTime else { return "All day" }
  return constraint.endTime.map { "\(start)–\($0)" } ?? start
}

func calendarConstraintDetail(_ constraint: CalendarTripConstraint) -> String? {
  switch constraint.commitment?.occupancy {
  case .dayContext: nil
  case .busy: nil
  case .free: "Marked free in Calendar"
  case .tentative: "Tentative"
  case .unavailable: "Unavailable"
  case .unknown: "Availability unknown"
  case nil: "Calendar timing needs review"
  }
}
