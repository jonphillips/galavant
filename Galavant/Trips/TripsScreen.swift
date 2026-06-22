import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct TripsScreen: View {
  @State private var model = TripsListModel()
  @Environment(AppRouter.self) private var router
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    @Bindable var router = router
    Group {
      if horizontalSizeClass == .regular {
        // iPad/Mac: the split detail rebuilds when you flip sections, which *pops* a
        // pushed trip and clears the binding. So drill into a trip as an in-panel
        // overlay swap, driven purely by `router.openTrip` (the codebase's iPad
        // pattern) — it survives the rebuild because we own the state.
        if let trip = router.openTrip {
          TripPlanningView(trip: trip)
            .toolbar {
              ToolbarItem(placement: .topBarLeading) {
                Button { router.openTrip = nil } label: {
                  Label("Trips", systemImage: "chevron.backward")
                }
              }
            }
        } else {
          tripsList
        }
      } else {
        // iPhone: a real push (the tab stays alive, so it persists across flips).
        tripsList
          .navigationDestination(item: $router.openTrip) { trip in
            TripPlanningView(trip: trip)
          }
      }
    }
  }

  private var tripsList: some View {
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
    Button {
      router.openTrip = trip
    } label: {
      TripRow(trip: trip)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
  }
}

#Preview {
  let _ = prepareDependencies {
    try! $0.bootstrapDatabase()
  }
  NavigationStack {
    TripsScreen()
  }
  .environment(AppRouter())
}
