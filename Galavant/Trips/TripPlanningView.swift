import GalavantSchema
import SwiftUI
import SwiftUINavigation

/// One trip's planning surface: a segmented Ideas | Itinerary. Ideas shows the
/// pulled ideas grouped Shortlist / Scheduled / Considering (a `+` opens the
/// filterable pool as a bottom sheet to add more); Itinerary lays the scheduled
/// stops out by day (ADR-0004). The two tabs and the two sheets each live in
/// their own file; this is just the shell that wires them to the model.
struct TripPlanningView: View {
  @State private var model: TripPlanningModel

  init(trip: Trip) {
    _model = State(initialValue: TripPlanningModel(tripID: trip.id))
  }

  var body: some View {
    @Bindable var model = model
    Group {
      switch model.mode {
      case .ideas: TripIdeasView(model: model)
      case .itinerary: TripItineraryView(model: model)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      Picker("Mode", selection: $model.mode) {
        ForEach(TripPlanningModel.Mode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
    }
    .navigationTitle(model.trip?.name ?? "Trip")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      // Trip-level action sits on the leading side, away from the content's
      // add button on the trailing side.
      ToolbarItem(placement: .topBarLeading) {
        Button("Edit") { model.editButtonTapped() }
      }
      ToolbarItem(placement: .topBarTrailing) {
        switch model.mode {
        case .ideas:
          Button {
            model.addIdeasButtonTapped()
          } label: {
            Label("Add Ideas", systemImage: "plus")
          }
        case .itinerary:
          Button {
            model.addStopButtonTapped()
          } label: {
            Label("Add Stop", systemImage: "plus")
          }
        }
      }
    }
    .sheet(item: $model.destination.edit, id: \.id) { draft in
      TripFormView(draft: draft)
    }
    .sheet(
      isPresented: Binding(
        get: { model.destination?.is(\.addIdeas) ?? false },
        set: { model.destination = $0 ? .addIdeas : nil }
      )
    ) {
      AddIdeasSheet(model: model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.destination?.is(\.scheduleStop) ?? false },
        set: { model.destination = $0 ? .scheduleStop : nil }
      )
    ) {
      ScheduleStopSheet(model: model)
    }
    .task { model.seedLensIfNeeded() }
    .onChange(of: model.tripRegionIDs) { _, _ in model.reseedLens() }
  }
}
