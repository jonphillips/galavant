import GalavantSchema
import SwiftUI

/// The itinerary as a timeline (day-relative, never dates — docs/trip-time-model.md).
/// In the trip canvas's bottom sheet it shows one **focused day** (the day chip's
/// lens); with no focus it shows the whole trip — a "To Be Scheduled" bucket atop
/// the day-by-day layout. Each row taps to select its stop (the shared canvas
/// selection) and carries the `StopMenu` to set/move its day and time.
struct TripItineraryView: View {
  let model: TripPlanningModel
  let reconciliationModel: CalendarReconciliationModel
  /// On compact layouts this is the first list section, so it scrolls with the
  /// timeline instead of taking permanent vertical space above it.
  var showsInlineAdd = false
  /// When set, render only this day's stops (the canvas day lens). Nil = the
  /// whole trip.
  var focusedDay: Int?
  @State private var selectedCalendarConstraint: CalendarTripConstraint?
  @State private var pendingStopRemoval: PendingStopRemoval?

  private struct PendingStopRemoval {
    let stopID: TripIdea.ID
    let title: String
  }

  var body: some View {
    ScrollViewReader { proxy in
      content
        // Selecting a stop on the map scrolls the matching row into view (the
        // map→list half of the shared selection; list→map is the tap below).
        .onChange(of: model.canvasSelectedStopID) { _, id in
          guard let id else { return }
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        .sheet(item: $selectedCalendarConstraint) { constraint in
          CalendarConstraintDetailSheet(
            constraint: constraint,
            model: model,
            reconciliationModel: reconciliationModel)
        }
        .confirmationDialog("Remove Custom Stop?", item: $pendingStopRemoval) { removal in
          Button("Remove \(removal.title)", role: .destructive) {
            model.remove(removal.stopID)
          }
        } message: { removal in
          Text("\(removal.title) will be permanently removed from this trip.")
        }
    }
  }

  @ViewBuilder private var content: some View {
    if let day = focusedDay {
      focusedDayList(day)
    } else {
      fullItinerary
    }
  }

  /// One day's stops, for the canvas's day lens. Its header "+" adds straight
  /// onto this day.
  private func focusedDayList(_ day: Int) -> some View {
    let plan = model.plan
    let stops = plan.itinerary.first(where: { $0.number == day })?.stops ?? []
    let items = plan.itineraryItems(
      forDay: day, travelTimes: model.travelTimes, effectiveModes: model.effectiveModes,
      now: Date.now, tripStartDate: model.trip?.startDate,
      stays: plan.stays(coveringDay: day))
    let sequence = plan.locatedSequenceNumbers(forDay: day)
    let cells = focusedDayCells(stops: stops, items: items)
    return List {
      inlineAddSection
      Section {
        if items.isEmpty {
          Text("No stops on this day yet")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        } else if stops.isEmpty {
          ForEach(items) { item in itineraryRow(item, sequence: sequence) }
        } else {
          ForEach(cells.head) { item in itineraryRow(item, sequence: sequence) }
          ForEach(stops) { stop in
            focusedDayStopCell(
              stop,
              cell: cells.byStopID[stop.id] ?? FocusedDayStopCell(stop: stop),
              sequence: sequence)
          }
          .reorderable()
          ForEach(cells.tail) { item in itineraryRow(item, sequence: sequence) }
        }
      } header: {
        SectionHeader(
          label: dayLabel(day, trip: model.trip),
          day: day,
          model: model)
      }
    }
    // No custom `dragContainer`: `reorderContainer` is already its own drag
    // container and drop destination, and that built-in path resolves the drop
    // position correctly. A custom `dragContainer` (added earlier to gate pickup
    // to Anytime stops) turned this into a plain item-drag whose drop always
    // resolved back to the source's original slot — every reorder was a silent
    // no-op. Pickup gating instead lives in `reorderDayStops`, which no-ops a
    // non-`.day` source. This matches `TripIdeasView`, which reorders the same way.
    .reorderContainer(for: ResolvedStop.self) { difference in
      var reordered = stops
      difference.apply(to: &reordered)
      guard let sourceID = difference.sources.first else { return }
      model.reorderDayStops(reordered.map(\.id), on: day, moving: sourceID)
    }
  }

  /// The heterogeneous timeline (from `TripPlan.itineraryItems`) split into the
  /// buckets the day lens's single reorderable stop run needs:
  /// - `head`: every non-stop row *before* the first stop — home base, a morning
  ///   calendar constraint, the base connector. These render as static rows ABOVE
  ///   the reorderable `ForEach`, so they neither lift with a stop nor read as
  ///   glued to one. This is the common "attached rows" case, now un-glued.
  /// - each cell's `trailing`: the stop's outgoing travel connector, genuinely
  ///   stop-attached, kept folded into the cell.
  /// - each cell's `leading`: a boundary that falls *between* two stops (a midday
  ///   reservation, say). It can't become a static row inside the reorderable
  ///   `ForEach` until the sectioned overload works on a later beta (KNOWN-ISSUES),
  ///   so it stays folded — but rendered de-tinted + divider-separated so it still
  ///   reads as its own row, not part of the stop it rides with.
  /// - `tail`: rows after the last stop, static below the `ForEach`.
  private func focusedDayCells(
    stops: [ResolvedStop], items: [ItineraryItem]
  ) -> (head: [ItineraryItem], byStopID: [TripIdea.ID: FocusedDayStopCell], tail: [ItineraryItem]) {
    var cells = stops.map { FocusedDayStopCell(stop: $0) }
    var head: [ItineraryItem] = []
    var pending: [ItineraryItem] = []
    var currentStopIndex: Int?
    var nextStopIndex = 0

    for item in items {
      switch item {
      case .stop:
        guard nextStopIndex < cells.count else { continue }
        // Boundaries before the FIRST stop are hoisted out of the run entirely;
        // only those between later stops stay folded (the reorder constraint).
        if nextStopIndex == 0 {
          head = pending
        } else {
          cells[nextStopIndex].leading = pending
        }
        pending.removeAll(keepingCapacity: true)
        currentStopIndex = nextStopIndex
        nextStopIndex += 1
      case .connector(let connector)
        where connector.kind == .betweenStops || connector.kind == .toLodging:
        guard let currentStopIndex else {
          pending.append(item)
          continue
        }
        cells[currentStopIndex].trailing.append(item)
      default:
        pending.append(item)
      }
    }

    return (
      head,
      Dictionary(uniqueKeysWithValues: cells.map { ($0.stop.id, $0) }),
      pending)
  }

  private struct FocusedDayStopCell {
    let stop: ResolvedStop
    var leading: [ItineraryItem] = []
    var trailing: [ItineraryItem] = []
  }

  @ViewBuilder
  private func focusedDayStopCell(
    _ stop: ResolvedStop, cell: FocusedDayStopCell, sequence: [TripIdea.ID: Int]
  ) -> some View {
    // The selection tint sits on `stopRow` alone (a plain `.background`): a nested
    // `.listRowBackground` can't reach the row, and a cell-wide one would also tint
    // the folded between-stop boundary rows we're keeping visually distinct.
    // `stopRow` keeps its own `.listRowBackground` for the whole-trip path, where it
    // *is* the row. The cell carries row identity via `ForEach(stops)`, so
    // `stopRow`'s inner `.id` is redundant here.
    LifecycleSwipeActions(stop: stop, model: model, onRemove: requestStopRemoval) {
      VStack(alignment: .leading, spacing: 0) {
        // Between-stop boundaries ride in the cell (they can't leave the reorderable
        // ForEach yet), but the divider + stop-only tint keep them reading as their
        // own rows rather than glued to the stop.
        ForEach(cell.leading) { item in
          itineraryRow(item, sequence: sequence)
          Divider()
        }
        StopRow(
          model: model,
          resolved: stop,
          sequence: sequence,
          includesLifecycleSwipeActions: false,
          onRemove: requestStopRemoval)
          .background(
            model.canvasSelectedStopID == stop.id
              ? Color.accentColor.opacity(0.12) : Color.clear)
        ForEach(cell.trailing) { item in itineraryRow(item, sequence: sequence) }
      }
    }
  }

  /// The whole trip: the dayless bucket (only while it holds something — a stop
  /// reaches it by being demoted via `StopMenu`; an empty bucket is just hidden),
  /// then every day, each section's "+" adding a shortlisted idea straight into
  /// it. (Dragging stops between days is parked — List drag-and-drop times out on
  /// Xcode 27 beta 1; the `StopMenu`'s Move-to-Day / To-Be-Scheduled covers it.
  /// See KNOWN-ISSUES.)
  private var fullItinerary: some View {
    List {
      // Build the plan and the leg-mode map once for the whole list — both are
      // computed properties; reading them per day rebuilt the plan's leg-graph
      // O(days) times per layout pass and locked up large trips.
      let plan = model.plan
      let modes = model.effectiveModes
      inlineAddSection
      let bucket = plan.toBeScheduled
      if !bucket.isEmpty {
        Section {
          ForEach(bucket) { resolved in
            StopRow(model: model, resolved: resolved, onRemove: requestStopRemoval)
          }
        } header: {
          SectionHeader(label: "To Be Scheduled", day: nil, model: model)
        }
      }
      ForEach(plan.itinerary) { day in
        let items = plan.itineraryItems(
          forDay: day.number, travelTimes: model.travelTimes, effectiveModes: modes,
          now: Date.now, tripStartDate: model.trip?.startDate,
          stays: plan.stays(coveringDay: day.number))
        let sequence = plan.locatedSequenceNumbers(forDay: day.number)
        Section {
          if items.isEmpty {
            Text("No stops yet")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
          } else {
            ForEach(items) { item in itineraryRow(item, sequence: sequence) }
          }
        } header: {
          SectionHeader(
            label: dayLabel(day.number, trip: model.trip),
            day: day.number,
            model: model)
        }
      }
    }
  }

  @ViewBuilder private var inlineAddSection: some View {
    if showsInlineAdd {
      Section {
        TripAddButton(model: model, tab: .itinerary)
      }
    }
  }

  @ViewBuilder private func itineraryRow(
    _ item: ItineraryItem, sequence: [TripIdea.ID: Int] = [:]
  ) -> some View {
    switch item {
    case .stop(let resolved):
      StopRow(model: model, resolved: resolved, sequence: sequence, onRemove: requestStopRemoval)
    case .calendarConstraint(let constraint):
      CalendarConstraintRow(constraint: constraint) { selectedCalendarConstraint = $0 }
    case .connector(let connector):
      ConnectorRow(model: model, connector: connector)
    case .nowMarker:
      NowMarkerRow()
    case .checkIn(let stay):
      CheckRow(stay: stay, isCheckIn: true, onEdit: model.editStay)
    case .checkOut(let stay):
      CheckRow(stay: stay, isCheckIn: false, onEdit: model.editStay)
    case .homeBase(let stay):
      HomeBaseRow(
        stay: stay,
        isOverlapping: model.plan.overlappingStayIDs.contains(stay.id),
        onEdit: model.editStay)
    }
  }

  private func requestStopRemoval(_ stopID: TripIdea.ID, title: String) {
    pendingStopRemoval = PendingStopRemoval(stopID: stopID, title: title)
  }

}
