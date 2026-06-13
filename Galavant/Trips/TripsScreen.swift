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
          Label("No trips yet", systemImage: "suitcase")
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
          Label("Add Trip", systemImage: "plus")
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

/// Apply a single-collection reorder to an ordered array of identifiable items
/// (Apple's documented pattern for `reorderContainer`).
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
  func apply<C>(to collection: inout C)
  where C: RangeReplaceableCollection, C.Element: Identifiable, C.Element.ID == ItemID {
    let moving = Set(sources)
    guard !moving.isEmpty else { return }

    var moved: [C.Element] = []
    moved.reserveCapacity(moving.count)
    collection.removeAll { element in
      guard moving.contains(element.id) else { return false }
      moved.append(element)
      return true
    }

    switch destination.position {
    case .before(let id):
      let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
      collection.insert(contentsOf: moved, at: index)
    case .end:
      collection.append(contentsOf: moved)
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
