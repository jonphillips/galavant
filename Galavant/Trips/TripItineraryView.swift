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
  /// On compact layouts this is the first list section, so it scrolls with the
  /// timeline instead of taking permanent vertical space above it.
  var showsInlineAdd = false
  /// When set, render only this day's stops (the canvas day lens). Nil = the
  /// whole trip.
  var focusedDay: Int?
  @State private var selectedCalendarConstraint: CalendarTripConstraint?

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
          CalendarConstraintDetailSheet(constraint: constraint)
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
    let items = model.plan.itineraryItems(
      forDay: day, travelTimes: model.travelTimes, effectiveModes: model.effectiveModes,
      now: Date.now, tripStartDate: model.trip?.startDate,
      stays: model.plan.stays(coveringDay: day))
    let sequence = model.plan.locatedSequenceNumbers(forDay: day)
    return List {
      inlineAddSection
      Section {
        if items.isEmpty {
          Text("No stops on this day yet")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(items) { item in itineraryRow(item, sequence: sequence) }
        }
      } header: {
        sectionHeader(dayLabel(day, trip: model.trip), day: day)
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
      inlineAddSection
      let bucket = model.plan.toBeScheduled
      if !bucket.isEmpty {
        Section {
          ForEach(bucket) { resolved in stopRow(resolved) }
        } header: {
          sectionHeader("To Be Scheduled", day: nil)
        }
      }
      ForEach(model.plan.itinerary) { day in
        let items = model.plan.itineraryItems(
          forDay: day.number, travelTimes: model.travelTimes, effectiveModes: model.effectiveModes,
          now: Date.now, tripStartDate: model.trip?.startDate,
          stays: model.plan.stays(coveringDay: day.number))
        let sequence = model.plan.locatedSequenceNumbers(forDay: day.number)
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
          .font(.subheadline.monospaced())
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
    let time = isCheckIn ? stay.stay.checkInTime : stay.stay.checkOutTime
    return HStack(spacing: 12) {
      (isCheckIn ? Icon.checkIn : Icon.checkOut).image
        .foregroundStyle(.secondary)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(isCheckIn ? "Check in" : "Check out")
          .font(.subheadline.weight(.medium))
        Text(stay.content.title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if let time {
        Text(time).font(.subheadline.monospaced()).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { model.editStay(stay) }
  }

  /// A stop row: the stop content, optional info/edit buttons (idea-backed only),
  /// a pinned-reservation indicator (docs/trip-time-model.md §4), its
  /// `StopMenu`, and a tap. An idea-backed row taps to select on the shared
  /// canvas (the info button is its own hit target); a freeform row has no map
  /// pin to select, so it taps to open its inline editor instead (ADR-0010).
  private func stopRow(
    _ resolved: ResolvedStop, sequence: [TripIdea.ID: Int] = [:]
  ) -> some View {
    let isFreeform = resolved.idea == nil
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
    return VStack(alignment: .leading, spacing: 8) {
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
      if isFreeform {
        model.editFreeform(resolved)
      } else {
        model.selectStop(resolved.id)
      }
    }
    .id(resolved.id)
  }

  /// The trailing accessory cluster for a stop row: a pinned-reservation glyph and
  /// the `StopMenu`, plus (idea-backed rows only) the info/edit buttons. Extracted
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
      if let idea = resolved.idea {
        HStack(spacing: 14) {
          Button { model.showDetail(idea) } label: {
            Icon.info.image.foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          Button { model.editIdea(idea) } label: {
            Icon.edit.image.foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Edit title and details")
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
  /// Tap (long press / context menu) to switch mode or open Apple Maps for that leg.
  private func connectorRow(_ connector: TravelConnector) -> some View {
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
    }
    .padding(.vertical, 2)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
    .contentShape(Rectangle())
    .contextMenu {
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
    }
  }

}

private struct CalendarConstraintDetailSheet: View {
  let constraint: CalendarTripConstraint
  @Environment(\.dismiss) private var dismiss

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
      }
      .navigationTitle("Calendar Event")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
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
