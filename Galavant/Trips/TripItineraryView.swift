import GalavantPlaces
import GalavantSchema
import MapKit
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
        sectionHeader(dayLabel(day, trip: model.trip), day: day)
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
    lifecycleSwipeActions(for: stop) {
      VStack(alignment: .leading, spacing: 0) {
        // Between-stop boundaries ride in the cell (they can't leave the reorderable
        // ForEach yet), but the divider + stop-only tint keep them reading as their
        // own rows rather than glued to the stop.
        ForEach(cell.leading) { item in
          itineraryRow(item, sequence: sequence)
          Divider()
        }
        stopRow(stop, sequence: sequence, includesLifecycleSwipeActions: false)
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
          ForEach(bucket) { resolved in stopRow(resolved) }
        } header: {
          sectionHeader("To Be Scheduled", day: nil)
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
          sectionHeader(dayLabel(day.number, trip: model.trip), day: day.number)
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

  /// A section header with a trailing "+" that drops a shortlisted idea straight
  /// into this section — a day, or the To Be Scheduled bucket (`day == nil`). On a
  /// day a stay covers, a quiet home-base chip (🛏 hotel) sits under the label
  /// (ADR-0011); tapping it edits the stay.
  private func sectionHeader(_ label: String, day: Int?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
        Spacer()
        Button {
          model.addToSectionTapped(day: day)
        } label: {
          Icon.add.image
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Add to \(label)")
      }
      // The region menu lives in the header (only worth showing once a trip spans
      // 2+ regions); accommodations moved out to real timeline rows (check-in /
      // check-out / home-base) so the stay reads as part of the day, not a chip.
      if let day {
        HStack(spacing: 8) {
          if model.tripRegions.count >= 2 {
            dayRegionMenu(day: day)
          }
          dayTimeZoneMenu(day: day)
        }
      }
    }
  }

  /// A chip-styled menu to assign one of the trip's regions to this day (ADR-0012)
  /// — the region scopes the day and frames its empty map. Shown only on multi-region
  /// trips. "None" clears it. (Final styling is Jon's to tune.)
  private func dayRegionMenu(day: Int) -> some View {
    let assigned = model.dayRegion(forDay: day)
    return Menu {
      Picker("Region", selection: Binding(
        get: { assigned?.id },
        set: { model.setDayRegion($0, forDay: day) }
      )) {
        Text("None").tag(MapRegion.ID?.none)
        ForEach(model.tripRegions) { region in
          Text(region.name).tag(MapRegion.ID?.some(region.id))
        }
      }
    } label: {
      HStack(spacing: 5) {
        Icon.map.image.imageScale(.medium)
        Text(assigned?.name ?? "Set region").lineLimit(1)
      }
      .font(.subheadline)
      .foregroundStyle(assigned == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
    .buttonStyle(.borderless)
    .textCase(nil)
  }

  private func dayTimeZoneMenu(day: Int) -> some View {
    let assigned = model.dayTimeZone(forDay: day)
    return Menu {
      Button("Use trip default") { model.setDayTimeZone(nil, forDay: day) }
      Divider()
      ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { identifier in
        Button {
          model.setDayTimeZone(identifier, forDay: day)
        } label: {
          if identifier == assigned?.identifier {
            Label(identifier, systemImage: "checkmark")
          } else {
            Text(identifier)
          }
        }
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "clock")
        Text(assigned?.identifier ?? "Default").lineLimit(1)
      }
      .font(.subheadline)
      .foregroundStyle(assigned == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
    .buttonStyle(.borderless)
    .textCase(nil)
  }

  /// The persistent "you're based here" row on a stay's middle days (ADR-0011,
  /// promoted from a header chip to a real row). The bed glyph + hotel name, an
  /// advisory warning tint when the stay overlaps another (§6); tap to edit. Reads
  /// like the check-in/out rows so the home base is part of the day's timeline.
  private func homeBaseRow(_ stay: ResolvedStay) -> some View {
    let flagged = model.plan.overlappingStayIDs.contains(stay.id)
    return HStack(spacing: 12) {
      Icon.stay.image
        .foregroundStyle(flagged ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("Home base").font(.subheadline.weight(.medium))
        Text(stay.content.title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if flagged {
        Image(systemName: "exclamationmark.triangle.fill")
          .imageScale(.small)
          .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { model.editStay(stay) }
  }

  @ViewBuilder private func itineraryRow(
    _ item: ItineraryItem, sequence: [TripIdea.ID: Int] = [:]
  ) -> some View {
    switch item {
    case .stop(let resolved): stopRow(resolved, sequence: sequence)
    case .calendarConstraint(let constraint): calendarConstraintRow(constraint)
    case .connector(let connector): connectorRow(connector)
    case .nowMarker: nowMarkerRow
    case .checkIn(let stay): checkRow(stay, isCheckIn: true)
    case .checkOut(let stay): checkRow(stay, isCheckIn: false)
    case .homeBase(let stay): homeBaseRow(stay)
    }
  }

  private func calendarConstraintRow(_ constraint: CalendarTripConstraint) -> some View {
    Button {
      selectedCalendarConstraint = constraint
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "calendar.badge.clock")
          .foregroundStyle(.secondary)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text(constraint.title)
            .font(.subheadline.weight(.medium))
          if let detail = calendarConstraintDetail(constraint) {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let notes = constraint.notes {
            Text(notes)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        Text(constraint.displayTime ?? constraintTime(constraint))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        if constraint.notes != nil {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .buttonStyle(.plain)
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Calendar constraint, \(constraint.title), \(constraint.displayTime ?? constraintTime(constraint))"
        + (constraint.notes.map { ", Notes: \($0)" } ?? ""))
  }

  /// A stay boundary row — "Check in" on the stay's check-in day, "Check out" on
  /// its check-out day, with the hotel name and the optional clock time. Taps to
  /// edit the stay. Reads as an event in the timeline, distinct from a point stop.
  private func checkRow(_ stay: ResolvedStay, isCheckIn: Bool) -> some View {
    let display = isCheckIn ? stay.stay.checkInDisplay : stay.stay.checkOutDisplay
    return HStack(spacing: 12) {
      (isCheckIn ? Icon.checkIn : Icon.checkOut).image
        .foregroundStyle(.secondary)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(isCheckIn ? "Check in" : "Check out")
            .font(.subheadline.weight(.medium))
          if let official = display.officialParenthetical {
            Text("(\(official))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(stay.content.title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if let trailing = display.trailing {
        Text(trailing).font(.subheadline.monospaced()).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { model.editStay(stay) }
  }

  /// A stop row: the stop content, its pinned-reservation indicator
  /// (docs/trip-time-model.md §4), its `StopMenu`, and a tap. Tapping the name
  /// selects the stop on the shared canvas and, for idea-backed stops, opens the
  /// existing in-panel detail overlay; the pencil remains the explicit edit
  /// affordance. The custom reorder actions are intentionally non-visual: the
  /// physical-device VoiceOver check is still pending, so they preserve an
  /// accessibility path if `.reorderable()` does not expose one itself.
  private func stopRow(
    _ resolved: ResolvedStop,
    sequence: [TripIdea.ID: Int] = [:],
    includesLifecycleSwipeActions: Bool = true
  ) -> some View {
    let ring = model.plan.alternatives(forStop: resolved.id)
    let looseRing = ring.map { isLooseAlternativeSlot($0.activeMember.entry.schedule) } ?? false
    // A located stop wears its day-coloured map-pin number; everything else
    // (unlocated/freeform stops, and every non-day caller — the To-Be-Scheduled
    // bucket — passing an empty `sequence`) keeps the kind icon.
    let marker: PlanningRowMarker = sequence[resolved.id].map {
      .sequence($0, DayPalette.color(forDay: resolved.entry.dayNumber ?? 1))
    } ?? .kind
    // A loose ring still surfaces its effective-active member by name — the
    // collapsed row shows the current pick, with "· N options" signalling the
    // menu (ADR-0035 §5: the neutral rendering is presentation, and every ring
    // always has one effective-active member). A firm slot keeps the plain
    // active name (title == nil → content.title).
    let looseTitle = looseRing
      ? "\(resolved.content.title) · \(ring?.members.count ?? 0) options"
      : nil
    return lifecycleSwipeActions(for: resolved, enabled: includesLifecycleSwipeActions) {
      VStack(alignment: .leading, spacing: 8) {
        if let ring {
          AlternativeGroupHeader(model: model, ring: ring)
        }
        PlanningRow(
          content: resolved.content,
          title: looseTitle,
          note: resolved.entry.calendarNotes ?? resolved.entry.inlineNote,
          subtitle: .none,
          marker: marker
        ) {
          stopRowAccessory(resolved)
        }
        // The alternatives affordance (cycle + "N of M" + disclosure) gets its own
        // row under the title, aligned past the pin marker — in the trailing cluster
        // it fought the schedule label ("Lunch") for width and the badge collapsed.
        if let ring {
          AlternativeSlotControls(model: model, ring: ring)
            .padding(.leading, 38)
        }
        if let ring, model.isAlternativeDisclosureExpanded(ring.groupID) {
          AlternativeSlotDisclosure(model: model, ring: ring)
        }
      }
      .listRowBackground(
        model.canvasSelectedStopID == resolved.id ? Color.accentColor.opacity(0.12) : nil
      )
      .contentShape(Rectangle())
      .onTapGesture {
        model.selectStop(resolved.id)
        if let idea = resolved.idea {
          model.showDetail(idea)
        }
      }
      .accessibilityActions {
        if case .day = resolved.entry.schedule {
          Button("Move Earlier in Day") {
            model.moveStopEarlier(resolved)
          }
          .disabled(!model.canMoveStopEarlier(resolved))
          Button("Move Later in Day") {
            model.moveStopLater(resolved)
          }
          .disabled(!model.canMoveStopLater(resolved))
        }
      }
      .id(resolved.id)
    }
  }

  @ViewBuilder
  private func lifecycleSwipeActions<Content: View>(
    for stop: ResolvedStop,
    enabled: Bool = true,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if enabled {
      content()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          if stop.entry.dayNumber != nil,
            model.calendarTimeAuthority(for: stop.id) != .linked
          {
            Button {
              model.sendToBeScheduled(stop.id)
            } label: {
              Label("To Be Scheduled", systemImage: Icon.toBeScheduled.systemName)
            }
          }
          if stop.idea != nil {
            Button {
              model.unschedule(stop.id)
            } label: {
              Label("Move to Shortlist", systemImage: Icon.revert.systemName)
            }
          }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: stop.idea != nil) {
          Button {
            model.markSkipped(stop.id)
          } label: {
            Label("Mark Skipped", systemImage: Icon.skip.systemName)
          }
          .tint(.orange)
          if stop.idea == nil {
            Button(role: .destructive) {
              pendingStopRemoval = PendingStopRemoval(
                stopID: stop.id, title: stop.content.title)
            } label: {
              Label("Remove", systemImage: Icon.delete.systemName)
            }
          }
        }
    } else {
      content()
    }
  }

  /// The trailing accessory cluster for a stop row: a pinned-reservation glyph and
  /// the `StopMenu`, plus the pencil button. Extracted
  /// from `stopRow` to keep that view builder within the body-length gate.
  @ViewBuilder
  private func stopRowAccessory(_ resolved: ResolvedStop) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
      HStack(spacing: 14) {
        if resolved.entry.pinnedDate != nil {
          Icon.pinnedReservation.image
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pinned reservation")
        }
        StopMenu(model: model, stop: resolved)
      }
      if resolved.idea != nil {
        HStack(spacing: 14) {
          Button { model.editStop(resolved) } label: {
            Icon.edit.image.foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Edit title and details")
        }
      } else {
        HStack(spacing: 14) {
          Button { model.editFreeform(resolved) } label: {
            Icon.edit.image.foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Edit custom stop")
        }
      }
    }
  }

  /// A "you are here" divider — red line with "Now" label, appears at the current
  /// moment in today's day section. Non-interactive; just orients you on the timeline.
  private var nowMarkerRow: some View {
    HStack(spacing: 8) {
      Rectangle()
        .fill(Color.red)
        .frame(height: 1)
      Text("Now")
        .font(.caption.bold())
        .foregroundStyle(.red)
        .fixedSize()
      Rectangle()
        .fill(Color.red)
        .frame(height: 1)
    }
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    .allowsHitTesting(false)
  }

  /// A compact interstitial row showing the travel time and mode to the next stop.
  /// Tap to switch mode or open Apple Maps for that leg.
  private func connectorRow(_ connector: TravelConnector) -> some View {
    // A tap-triggered `Menu`, not a `.contextMenu`: when this row is folded into a
    // reorderable stop cell (the day lens), a long-press context menu competes with
    // the reorder lift — both are long-presses, so a quick drag never commits the
    // reorder. A `Menu` opens on tap, leaving the long-press to the reorder alone.
    Menu {
      // Mode picker — checkmark on the current mode via Picker-in-menu idiom.
      Picker("Transport", selection: Binding(
        get: { connector.mode },
        set: { model.setMode($0, for: connector.leg) }
      )) {
        ForEach(TransportMode.allCases, id: \.self) { mode in
          Label(mode.label, systemImage: mode.systemImageName).tag(mode)
        }
      }
      Divider()
      Button {
        openInMaps(connector: connector)
      } label: {
        Label("Open in Maps", systemImage: "map")
      }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: connector.mode.systemImageName)
          .imageScale(.small)
          .foregroundStyle(.tertiary)
        if connector.kind == .betweenLodgings || connector.kind == .toLodging {
          Text("Travel to \(connector.to.title)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Group {
          if let tt = connector.travelTime {
            Text(tt.formatted(mode: connector.mode))
          } else {
            Text("…")
          }
        }
        .font(.caption)
        .foregroundStyle(connector.travelTime == nil ? .tertiary : .secondary)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .padding(.vertical, 2)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
  }

}

private struct CalendarConstraintDetailSheet: View {
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

private func isLooseAlternativeSlot(_ schedule: Schedule) -> Bool {
  switch schedule {
  case .day, .unscheduled: true
  case .daypart, .timed: false
  }
}

private func constraintTime(_ constraint: CalendarTripConstraint) -> String {
  guard let start = constraint.startTime else { return "All day" }
  return constraint.endTime.map { "\(start)–\($0)" } ?? start
}

private func calendarConstraintDetail(_ constraint: CalendarTripConstraint) -> String? {
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
