import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct TripsScreen: View {
  @State private var model = TripsListModel()

  var body: some View {
    List {
      certaintySection(model.sections.dated, "Dated")
      certaintySection(model.sections.targeted, "Targeted")
      somedaySection
    }
    .reorderContainer(for: Trip.self) { difference in
      var someday = model.sections.someday
      difference.apply(to: &someday)
      model.reorderSomeday(someday.map(\.id))
    }
    .navigationDestination(for: Trip.self) { trip in
      TripPlanningView(trip: trip)
    }
    .overlay {
      if model.trips.isEmpty {
        ContentUnavailableView {
          Icon.trips.label("No trips yet")
        } description: {
          Text("Tap + to start a trip — a vague someday, a targeted season, or dated dates.")
        }
      }
    }
    .navigationTitle("Trips")
    .toolbar {
      ToolbarItem {
        Button {
          model.addTripButtonTapped()
        } label: {
          Icon.add.label("Add Trip")
        }
      }
    }
    .sheet(item: $model.destination.form, id: \.id) { draft in
      TripFormView(draft: draft)
    }
  }

  @ViewBuilder
  private var somedaySection: some View {
    let someday = model.sections.someday
    if !someday.isEmpty {
      Section("Someday") {
        ForEach(someday) { trip in
          tripButton(trip)
        }
        .onDelete { model.deleteTrips(someday, at: $0) }
        .reorderable()
      }
    }
  }

  @ViewBuilder
  private func certaintySection(_ trips: [Trip], _ title: String) -> some View {
    if !trips.isEmpty {
      Section(title) {
        ForEach(trips) { trip in
          tripButton(trip)
        }
        .onDelete { model.deleteTrips(trips, at: $0) }
      }
    }
  }

  private func tripButton(_ trip: Trip) -> some View {
    NavigationLink(value: trip) {
      TripRow(trip: trip)
    }
  }
}

#Preview {
  let _ = prepareDependencies {
    try! $0.bootstrapDatabase()
  }
  NavigationStack {
    TripsScreen()
  }
}
