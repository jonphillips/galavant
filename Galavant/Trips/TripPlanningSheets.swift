import CoreLocation
import GalavantSchema
import SwiftUI

/// The Add-Ideas bottom sheet: the pool scoped by the trip's filter lens, each
/// row carrying the two one-tap state icons (`questionmark.bubble` = considering,
/// `star` = shortlist). Pulled up from the bottom over the Ideas tab.
struct AddIdeasSheet: View {
  let model: TripPlanningModel

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.filteredPool) { idea in
          let status = model.status(for: idea)
          PlanningRow(idea: idea) {
            HStack(spacing: 18) {
              // Considering (thought bubble) and Shortlist (star) — one tap each
              // to set the state; the lit one shows where it sits. Tapping the
              // lit icon removes it from the trip.
              addToggle("questionmark.bubble", on: status == .considering) {
                model.tapConsidering(idea)
              }
              addToggle("star", on: status?.isOnShortlist == true) {
                model.tapShortlist(idea)
              }
            }
          }
        }
      }
      .overlay {
        if model.filteredPool.isEmpty {
          ContentUnavailableView {
            Icon.ideas.label("No ideas to pull")
          } description: {
            Text(model.isFiltering ? "No pool ideas match the filter." : "Capture ideas first on the Ideas screen.")
          }
        }
      }
      .navigationTitle("Add Ideas")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { filterMenu }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.destination = nil }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  /// One of the two quick-state icons; lit (filled + tinted) when the row is in
  /// that state.
  private func addToggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: on ? "\(symbol).fill" : symbol)
        .imageScale(.large)
        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }

  private var filterMenu: some View {
    @Bindable var model = model
    return Menu {
      Menu("Regions") {
        ForEach(model.sortedRegions) { region in
          Button {
            model.toggleRegion(region.id)
          } label: {
            checked(region.name, on: model.selectedRegionIDs.contains(region.id))
          }
        }
      }
      Menu("Kinds") {
        ForEach(IdeaKind.allCases, id: \.self) { kind in
          Button {
            model.toggleKind(kind)
          } label: {
            checked(kind.label, on: model.selectedKinds.contains(kind))
          }
        }
      }
      Menu("Tags") {
        ForEach(model.sortedTags) { tag in
          Button {
            model.toggleTag(tag.id)
          } label: {
            checked(tag.name, on: model.selectedTagIDs.contains(tag.id))
          }
        }
      }
      Toggle("Show visited", isOn: $model.includeVisited)
      if model.isFiltering {
        Button("Clear filters", role: .destructive) { model.clearFilters() }
      }
    } label: {
      Label(
        "Filter",
        systemImage: model.isFiltering
          ? Icon.filterActive.systemName
          : "line.3.horizontal.decrease.circle"
      )
    }
  }

  @ViewBuilder
  private func checked(_ title: String, on: Bool) -> some View {
    if on {
      Label(title, systemImage: Icon.checkmark.systemName)
    } else {
      Text(title)
    }
  }
}

struct AlternativeAddMenu: View {
  let model: TripPlanningModel
  let targetStopID: TripIdea.ID

  var body: some View {
    Menu {
      Button("From Shortlist…", systemImage: Icon.shortlist.systemName) {
        model.addAlternativeButtonTapped(to: targetStopID)
      }
      Button("Custom Stop…", systemImage: Icon.addInline.systemName) {
        model.addCustomAlternativeButtonTapped(to: targetStopID)
      }
    } label: {
      Label("Add Alternative", systemImage: Icon.addInline.systemName)
    }
  }
}

/// Edit entry-scoped fields for an idea-backed stop. The shared Idea's fields stay
/// behind the explicit link so this sheet cannot accidentally edit cross-trip data.
struct StopEditorSheet: View {
  let model: TripPlanningModel
  @State private var draft: StopEditorDraft
  @Environment(\.dismiss) private var dismiss

  init(model: TripPlanningModel, draft: StopEditorDraft) {
    self.model = model
    _draft = State(initialValue: draft)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Stop Note") {
          TextField("Optional details", text: $draft.note, axis: .vertical)
            .lineLimit(1...3)
        }
        Section("Reservation") {
          if draft.calendarLinked {
            Label("Time from Shared Calendar", systemImage: "calendar.badge.checkmark")
          } else {
            BookingFields(draft: $draft.booking)
          }
        }
        Section {
          AlternativeAddMenu(model: model, targetStopID: draft.stopID)
        } header: {
          Text("Alternatives")
        } footer: {
          Text("Add another option to this itinerary slot.")
        }
        if let idea = draft.idea {
          Section {
            Button {
              model.editIdea(idea)
            } label: {
              Label("Edit Shared Idea", systemImage: Icon.edit.systemName)
            }
          } footer: {
            Text("The stop title and pool details belong to the shared Idea.")
          }
        }
      }
      .navigationTitle(draft.stopTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { model.saveStop(draft) }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct BookingFields: View {
  @Binding var draft: BookingFieldsDraft

  var body: some View {
    Toggle("Pinned reservation", isOn: $draft.isPinned)
    if draft.isPinned {
      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
      TextField("Confirmation number", text: $draft.confirmationNumber)
      TextField("Booking URL", text: $draft.bookingURL)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Party size", text: $draft.partySize)
        .keyboardType(.numberPad)
    }
  }
}

/// Author or edit a freeform itinerary stop — a custom stop with no pool idea
/// ("lunch", "train to Aarhus", "check in"). One sheet for both. When creating,
/// a day picker (default: To Be Scheduled) lands it directly; when editing, the
/// content, note, and reservation change — day placement is the `StopMenu`'s job,
/// as for any stop (ADR-0010 Slice 3). The title is required; the note, location,
/// and reservation are optional.
struct FreeformStopSheet: View {
  let model: TripPlanningModel
  @State private var draft: FreeformStopDraft
  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool

  init(model: TripPlanningModel, draft: FreeformStopDraft) {
    self.model = model
    _draft = State(initialValue: draft)
  }

  private var isEditing: Bool { draft.stopID != nil }
  private var isAlternative: Bool { draft.alternativeToStopID != nil }
  private var canSave: Bool {
    !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canEditBooking: Bool {
    guard let stopID = draft.stopID else { return true }
    return model.calendarTimeAuthority(for: stopID) == .manual
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Stop") {
          TextField("Title", text: $draft.title)
            .focused($titleFocused)
        }
        Section("Note") {
          TextField("Optional details", text: $draft.note, axis: .vertical)
            .lineLimit(2...5)
        }
        if canEditBooking {
          Section("Reservation") {
            BookingFields(draft: $draft.booking)
          }
        }
        if isEditing && !isAlternative, let stopID = draft.stopID {
          Section {
            AlternativeAddMenu(model: model, targetStopID: stopID)
          } header: {
            Text("Alternatives")
          } footer: {
            Text("Add another option to this itinerary slot.")
          }
        }
        Section("Location") {
          if draft.coordinate == nil {
            FreeformStopLocationMap(
              coordinate: $draft.coordinate,
              title: draft.title,
              fallbackRegion: model.plan.framingCoordinates(forDay: nil).mapRegion)
              .frame(height: 220)
              .listRowInsets(EdgeInsets())
          }

          NavigationLink {
            FreeformStopLocationSearchView { place in
              draft.coordinate = CLLocationCoordinate2D(
                latitude: place.latitude, longitude: place.longitude)
              if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.title = place.name
              }
            }
          } label: {
            Label(
              draft.coordinate == nil ? "Search for a place" : "Choose a different place",
              systemImage: "magnifyingglass")
          }
          if draft.coordinate != nil {
            Button("Clear location", role: .destructive) {
              draft.coordinate = nil
            }
          }
        }
        // Placement is offered only at create time; editing leaves it to the
        // StopMenu, as for any stop.
        if !isEditing && !isAlternative {
          Section("When") {
            Picker("Day", selection: $draft.day) {
              Text("To Be Scheduled").tag(Int?.none)
              ForEach(1...(model.trip?.lengthInDays ?? 1), id: \.self) { n in
                Text(dayLabel(n, trip: model.trip)).tag(Int?.some(n))
              }
            }
          }
        }
      }
      .navigationTitle(isEditing ? "Edit Stop" : isAlternative ? "Add Alternative" : "Add Custom Stop")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.destination = nil
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isEditing ? "Save" : "Add") { model.saveFreeform(draft) }.disabled(!canSave)
        }
      }
      .onAppear { titleFocused = !isEditing }
      .onChange(of: draft.coordinate?.latitude) { _, _ in model.updateFreeformDraftCoordinate(draft.coordinate) }
      .onChange(of: draft.coordinate?.longitude) { _, _ in model.updateFreeformDraftCoordinate(draft.coordinate) }
    }
    .presentationDetents([.large]).presentationDragIndicator(.visible)
  }
}

/// Author or edit an accommodation (ADR-0011). One sheet for both entry points:
/// **"Stay here"** seeds a pool hotel (`ideaID` set, name shown read-only) and
/// **"Add lodging"** is a freeform stay (title + note). Both pick the night span
/// (check-in day → check-out day, the latter always after the former) and an
/// optional check-in / check-out time; absent a time the rows sort to evening /
/// morning. The span pickers can't express an invalid range, so Save is gated only
/// on a freeform title being present.
struct StaySheet: View {
  let model: TripPlanningModel
  @State private var draft: StayDraft
  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool

  init(model: TripPlanningModel, draft: StayDraft) {
    self.model = model
    _draft = State(initialValue: draft)
  }

  private var isEditing: Bool { draft.stayID != nil }
  private var tripLength: Int { max(2, model.trip?.lengthInDays ?? 2) }
  private var canSave: Bool {
    draft.isIdeaBacked
      || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        // A stay can tie to a pool hotel (so it gets a map pin, ADR-0011) or carry
        // a custom name. The picker offers both; a custom name reveals the text
        // fields.
        Section("Hotel") {
          Picker("Hotel", selection: $draft.ideaID) {
            Text("Custom name").tag(Idea.ID?.none)
            ForEach(model.lodgingIdeas) { idea in
              Text(idea.name).tag(Idea.ID?.some(idea.id))
            }
          }
          if draft.ideaID == nil {
            TextField("Name (e.g. Airbnb — Old Town)", text: $draft.title)
              .focused($titleFocused)
          }
        }
        if draft.ideaID == nil {
          Section("Note") {
            TextField("Optional details", text: $draft.note, axis: .vertical)
              .lineLimit(2...5)
          }
        }
        Section("Check-in") {
          dayPicker(selection: $draft.checkInDay, range: 1...(tripLength - 1))
            .onChange(of: draft.checkInDay) { _, day in
              if draft.checkOutDay <= day { draft.checkOutDay = day + 1 }
            }
          timeRow(label: "Official", time: $draft.checkInTime, seed: "15:00")
          timeRow(
            label: "Planned", time: $draft.plannedCheckInTime,
            seed: draft.checkInTime ?? "15:00")
        }
        Section("Check-out") {
          dayPicker(selection: $draft.checkOutDay, range: (draft.checkInDay + 1)...tripLength)
          timeRow(label: "Official", time: $draft.checkOutTime, seed: "10:00")
          timeRow(
            label: "Planned", time: $draft.plannedCheckOutTime,
            seed: draft.checkOutTime ?? "10:00")
        }
        if isEditing {
          Section {
            Button("Remove Stay", systemImage: Icon.delete.systemName, role: .destructive) {
              if let id = draft.stayID { model.removeStay(id) }
              dismiss()
            }
          }
        }
      }
      .navigationTitle(isEditing ? "Edit Stay" : "Add Lodging")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isEditing ? "Save" : "Add") { model.saveStay(draft) }.disabled(!canSave)
        }
      }
      .onAppear { titleFocused = !isEditing && !draft.isIdeaBacked }
    }
    .presentationDetents([.medium, .large])
  }

  private func dayPicker(selection: Binding<Int>, range: ClosedRange<Int>) -> some View {
    Picker("Day", selection: selection) {
      ForEach(Array(range), id: \.self) { n in
        Text(dayLabel(n, trip: model.trip)).tag(n)
      }
    }
  }

  /// An optional `"HH:mm"` time: a toggle to set one, then an hour-minute picker.
  /// Off ⇒ nil (sorts to the default evening/morning slot).
  @ViewBuilder private func timeRow(label: String, time: Binding<String?>, seed: String) -> some View {
    Toggle("Set \(label.lowercased())", isOn: Binding(
      get: { time.wrappedValue != nil },
      set: { time.wrappedValue = $0 ? (time.wrappedValue ?? seed) : nil }
    ))
    if time.wrappedValue != nil {
      DatePicker(
        label,
        selection: Binding(
          get: { Self.date(from: time.wrappedValue ?? seed) },
          set: { time.wrappedValue = Self.hhmm(from: $0) }
        ),
        displayedComponents: .hourAndMinute)
    }
  }

  private static func hhmm(from date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
  }

  private static func date(from hhmm: String) -> Date {
    let parts = hhmm.split(separator: ":")
    var c = DateComponents()
    c.hour = parts.first.flatMap { Int($0) } ?? 12
    c.minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    return Calendar.current.date(from: c) ?? .now
  }
}

/// Give a placed stop an exact clock time (ADR-0033 Slice 4) — the app's first
/// stop time editor. `start` is required (a `.timed` stop has one); `end` is
/// optional via the same toggle idiom as the stay editor. The `start` field is
/// pre-filled by the caller from `Schedule.suggestedTime` over the day's
/// neighbors, so the common case is confirm-not-type. "Remove Time" drops back to
/// a bare "Anytime" placement on the same day.
struct StopTimeSheet: View {
  let model: TripPlanningModel
  @State private var draft: StopTimeDraft
  @Environment(\.dismiss) private var dismiss

  init(model: TripPlanningModel, draft: StopTimeDraft) {
    self.model = model
    _draft = State(initialValue: draft)
  }

  private var stopTitle: String? {
    model.orderedStops(onDay: draft.day).first { $0.id == draft.stopID }?.content.title
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Start") {
          DatePicker(
            "Time",
            selection: Binding(
              get: { Self.date(from: draft.start) },
              set: { draft.start = Self.hhmm(from: $0) }),
            displayedComponents: .hourAndMinute)
        }
        Section("End") {
          Toggle("Set end time", isOn: Binding(
            get: { draft.end != nil },
            set: { draft.end = $0 ? (draft.end ?? Self.hourAfter(draft.start)) : nil }))
          if draft.end != nil {
            DatePicker(
              "Time",
              selection: Binding(
                get: { Self.date(from: draft.end ?? draft.start) },
                set: { draft.end = Self.hhmm(from: $0) }),
              displayedComponents: .hourAndMinute)
          }
        }
        Section {
          Button("Remove Time", systemImage: Icon.timeOfDay.systemName, role: .destructive) {
            model.clearStopTime(draft)
          }
        } footer: {
          Text("Removing the time keeps the stop on the day as “Anytime.”")
        }
      }
      .navigationTitle(stopTitle ?? "Set Time")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { model.saveStopTime(draft) }
        }
      }
    }
    .presentationDetents([.medium])
  }

  private static func hhmm(from date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
  }

  private static func date(from hhmm: String) -> Date {
    let parts = hhmm.split(separator: ":")
    var c = DateComponents()
    c.hour = parts.first.flatMap { Int($0) } ?? 12
    c.minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    return Calendar.current.date(from: c) ?? .now
  }

  /// One hour past `start` (clamped within the day) — the seed when the user first
  /// toggles an end time on.
  private static func hourAfter(_ hhmm: String) -> String {
    let parts = hhmm.split(separator: ":")
    let hour = parts.first.flatMap { Int($0) } ?? 12
    let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let clamped = Swift.min(hour * 60 + minute + 60, 24 * 60 - 1)
    return String(format: "%02d:%02d", clamped / 60, clamped % 60)
  }
}
