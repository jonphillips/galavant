import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct TripsScreen: View {
  @State private var model = TripsListModel()
  @State private var editingDraft: Trip.Draft?
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
    .sheet(item: $editingDraft, id: \.id) { draft in
      TripFormView(draft: draft)
    }
  }

  /// Two-up on iPhone, wider trips get more columns as space allows — the grid
  /// stays photo-forward without the cards ever getting tiny.
  private let columns = [GridItem(.adaptive(minimum: 165), spacing: 16)]

  private var tripsList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 28) {
        certaintySection(model.sections.dated, "Dated")
        certaintySection(model.sections.targeted, "Targeted")
        somedaySection
      }
      .padding(16)
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

  /// Someday is the reorderable backlog: drag-to-reorder the grid, persisting the
  /// new order (ADR-0032 grid keeps the old `List`'s manual ordering).
  @ViewBuilder
  private var somedaySection: some View {
    let someday = model.sections.someday
    if !someday.isEmpty {
      section("Someday") {
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(someday) { trip in
            tripCard(trip)
          }
          .reorderable()
        }
        .reorderContainer(for: Trip.self) { difference in
          var order = model.sections.someday
          difference.apply(to: &order)
          model.reorderSomeday(order.map(\.id))
        }
      }
    }
  }

  @ViewBuilder
  private func certaintySection(_ trips: [Trip], _ title: String) -> some View {
    if !trips.isEmpty {
      section(title) {
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(trips) { trip in
            tripCard(trip)
          }
        }
      }
    }
  }

  private func section(
    _ title: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3.weight(.semibold))
      content()
    }
  }

  private func tripCard(_ trip: Trip) -> some View {
    ZStack(alignment: .topTrailing) {
      Button {
        router.openTrip = trip
      } label: {
        TripCard(trip: trip)
      }
      .buttonStyle(.plain)

      Menu {
        editMenuItem(trip)
        deleteMenuItem(trip)
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.title3)
          .padding(8)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Trip actions")
    }
    .contextMenu {
      editMenuItem(trip)
      deleteMenuItem(trip)
    }
  }

  private func editMenuItem(_ trip: Trip) -> some View {
    Button {
      editingDraft = Trip.Draft(trip)
    } label: {
      Label("Edit", systemImage: "pencil")
    }
  }

  private func deleteMenuItem(_ trip: Trip) -> some View {
    Button(role: .destructive) {
      model.deleteTrip(trip)
    } label: {
      Label("Delete", systemImage: "trash")
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
  .environment(AppRouter())
}
