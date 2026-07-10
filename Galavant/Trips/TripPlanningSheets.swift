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

/// Drop a shortlisted idea into one itinerary section — a specific day, or the
/// To Be Scheduled bucket — chosen by that section's "+". The day is fixed by
/// the target, so adding is a single tap: tap an idea and it lands (anytime on
/// that day; refine the time later via `StopMenu`). Freeform stops are never
/// shortlisted (ADR-0010), so every row here is idea-backed.
struct PlaceIdeaSheet: View {
  let model: TripPlanningModel
  let target: PlaceIdeaTarget
  @Environment(\.dismiss) private var dismiss
  @Environment(AppRouter.self) private var router

  private var sectionLabel: String {
    target.day.map { dayLabel($0, trip: model.trip) } ?? "To Be Scheduled"
  }

  /// The day's assigned region, if any (ADR-0012) — names the browse hand-off and
  /// pre-toggles it on the Ideas screen.
  private var dayRegion: MapRegion? {
    target.day.flatMap { model.dayRegion(forDay: $0) }
  }

  /// Hand off to the Ideas shopping surface scoped to this trip + the day's region
  /// (ADR-0013) — the way to browse the *whole* pool for this day, not just the
  /// shortlist. Dismiss first so the sheet doesn't fight the screen switch.
  private func browse() {
    dismiss()
    router.browseIdeas(forTrip: model.tripID, regionID: dayRegion?.id)
  }

  private var browseLabel: String {
    dayRegion.map { "Browse \($0.name) Ideas" } ?? "Browse Ideas"
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.plan.shortlist.isEmpty {
          ContentUnavailableView {
            Icon.shortlist.label("Nothing shortlisted yet")
          } description: {
            Text("Browse the pool to find ideas for this day, then shortlist them to drop here.")
          } actions: {
            Button(action: browse) {
              Label(browseLabel, systemImage: Icon.map.systemName)
            }
            .buttonStyle(.borderedProminent)
          }
        } else {
          List {
            ForEach(model.plan.shortlist) { resolved in
              Button {
                model.placeIdea(resolved.id, on: target.day)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: resolved.content.idea?.kind?.systemImage ?? "mappin.and.ellipse")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                  Text(resolved.content.title).foregroundStyle(.primary)
                  Spacer()
                }
              }
            }
          }
        }
      }
      .navigationTitle("Add to \(sectionLabel)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        // Browse the full pool for this day on the Ideas shopping surface (ADR-0013).
        ToolbarItem(placement: .primaryAction) {
          Button(action: browse) {
            Label(browseLabel, systemImage: Icon.map.systemName)
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Author or edit a freeform itinerary stop — a custom stop with no pool idea
/// ("lunch", "train to Aarhus", "check in"). One sheet for both. When creating,
/// a day picker (default: To Be Scheduled) lands it directly; when editing, only
/// the content changes — day placement is the `StopMenu`'s job, as for any stop
/// (ADR-0010 Slice 3). The title is required; the note is optional.
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
  private var canSave: Bool {
    !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // Placement is offered only at create time; editing leaves it to the
        // StopMenu, as for any stop.
        if !isEditing {
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
      .navigationTitle(isEditing ? "Edit Stop" : "Add Custom Stop")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isEditing ? "Save" : "Add") { model.saveFreeform(draft) }.disabled(!canSave)
        }
      }
      .onAppear { titleFocused = !isEditing }
    }
    .presentationDetents([.medium])
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
          timeRow(label: "Time", time: $draft.checkInTime, seed: "15:00")
        }
        Section("Check-out") {
          dayPicker(selection: $draft.checkOutDay, range: (draft.checkInDay + 1)...tripLength)
          timeRow(label: "Time", time: $draft.checkOutTime, seed: "10:00")
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
