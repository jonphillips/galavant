import GalavantSchema
import SwiftUI
struct SectionHeader: View {
  let label: String
  let day: Int?
  let model: TripPlanningModel

  var body: some View {
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
      if let day {
        HStack(spacing: 8) {
          if model.tripRegions.count >= 2 {
            DayRegionMenu(day: day, model: model)
          }
          DayTimeZoneMenu(day: day, model: model)
        }
      }
    }
  }
}
struct DayRegionMenu: View {
  let day: Int
  let model: TripPlanningModel

  var body: some View {
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
}
struct DayTimeZoneMenu: View {
  let day: Int
  let model: TripPlanningModel

  var body: some View {
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
}
struct HomeBaseRow: View {
  let stay: ResolvedStay
  let isOverlapping: Bool
  let onEdit: (ResolvedStay) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Icon.stay.image
        .foregroundStyle(isOverlapping ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("Home base").font(.subheadline.weight(.medium))
        Text(stay.content.title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if isOverlapping {
        Image(systemName: "exclamationmark.triangle.fill")
          .imageScale(.small)
          .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { onEdit(stay) }
  }
}
struct CalendarConstraintRow: View {
  let constraint: CalendarTripConstraint
  let onSelect: (CalendarTripConstraint) -> Void

  var body: some View {
    Button {
      onSelect(constraint)
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
}
struct CheckRow: View {
  let stay: ResolvedStay
  let isCheckIn: Bool
  let onEdit: (ResolvedStay) -> Void

  var body: some View {
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
    .onTapGesture { onEdit(stay) }
  }
}

struct StopRow: View {
  let model: TripPlanningModel
  let resolved: ResolvedStop
  var sequence: [TripIdea.ID: Int] = [:]
  var includesLifecycleSwipeActions = true
  let onRemove: (TripIdea.ID, String) -> Void

  var body: some View {
    let ring = model.plan.alternatives(forStop: resolved.id)
    let looseRing = ring.map { isLooseAlternativeSlot($0.activeMember.entry.schedule) } ?? false
    let marker: PlanningRowMarker = sequence[resolved.id].map {
      .sequence($0, DayPalette.color(forDay: resolved.entry.dayNumber ?? 1))
    } ?? .kind
    let looseTitle = looseRing
      ? "\(resolved.content.title) · \(ring?.members.count ?? 0) options"
      : nil
    return LifecycleSwipeActions(
      stop: resolved,
      model: model,
      enabled: includesLifecycleSwipeActions,
      onRemove: onRemove
    ) {
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
          StopRowAccessory(model: model, resolved: resolved)
        }
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
}

struct StopRowAccessory: View {
  let model: TripPlanningModel
  let resolved: ResolvedStop

  var body: some View {
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
}

struct LifecycleSwipeActions<Content: View>: View {
  let stop: ResolvedStop
  let model: TripPlanningModel
  let enabled: Bool
  let onRemove: (TripIdea.ID, String) -> Void
  let content: () -> Content

  init(
    stop: ResolvedStop,
    model: TripPlanningModel,
    enabled: Bool = true,
    onRemove: @escaping (TripIdea.ID, String) -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.stop = stop
    self.model = model
    self.enabled = enabled
    self.onRemove = onRemove
    self.content = content
  }

  @ViewBuilder var body: some View {
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
              onRemove(stop.id, stop.content.title)
            } label: {
              Label("Remove", systemImage: Icon.delete.systemName)
            }
          }
        }
    } else {
      content()
    }
  }
}

struct NowMarkerRow: View {
  var body: some View {
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
}

struct ConnectorRow: View {
  let model: TripPlanningModel
  let connector: TravelConnector

  var body: some View {
    Menu {
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
