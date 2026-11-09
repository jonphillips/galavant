import CoreTransferable
import GalavantSchema
import SwiftUI

/// Edit the shape and purpose of each trip day (ADR-0054). Region assignments are
/// still persisted through the pure `TripSketch` span model and `TripDayRegion`
/// (ADR-0012); summaries and time-zone overrides remain their existing day rows.
///
/// Edits persist live through the model, so a per-region-run "Add lodging" or the
/// "Attach regions…" hand-off can leave for another editor without losing the
/// region work already done. The working copy is held locally for a responsive UI
/// and re-seeded each time the sheet is opened.
struct TripSketchSheet: View {
  let model: TripPlanningModel
  let presentation: TripSketchPresentation
  let defaultTimeZone: TimeZone?
  @State private var sketch: TripSketch
  @State private var summaryDrafts: [Int: String]
  @State private var moveRefusal: DayMoveRefusal?
  @FocusState private var focusedDay: Int?
  @Environment(\.dismiss) private var dismiss

  init(model: TripPlanningModel, presentation: TripSketchPresentation, defaultTimeZone: TimeZone?) {
    self.model = model
    self.presentation = presentation
    self.defaultTimeZone = defaultTimeZone
    _sketch = State(initialValue: model.sketch)
    _summaryDrafts = State(initialValue: [:])
  }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        form.onAppear { focusPresentedDay(using: proxy) }
      }
      .navigationTitle("Shape Trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            commitAllSummaries()
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .onDisappear(perform: commitAllSummaries)
    .onChange(of: focusedDay) { oldDay, _ in
      if let oldDay { commitSummary(for: oldDay) }
    }
    .alert(
      "Day didn't move",
      isPresented: Binding(
        get: { moveRefusal != nil },
        set: { if !$0 { moveRefusal = nil } })) {
      Button("OK", role: .cancel) { moveRefusal = nil }
    } message: {
      Text(moveRefusal?.localizedDescription ?? "")
    }
  }

  private var form: some View {
    Form {
      durationSection
      daysSection
    }
    .reorderContainer(for: TripDayDesign.self) { difference in
      reorderDays(difference)
    }
    .dragContainer(for: DayDesignDragPayload.self, itemID: \.id) { draggedID -> [DayDesignDragPayload] in
      guard dayDesigns.contains(where: { $0.id == draggedID && $0.lock == nil }) else { return [] }
      return [DayDesignDragPayload(id: draggedID)]
    }
  }

  private func focusPresentedDay(using proxy: ScrollViewProxy) {
    guard let day = presentation.focusDay else { return }
    guard (1...sketch.lengthInDays).contains(day) else { return }
    proxy.scrollTo(day, anchor: .center)
    focusedDay = day
  }

  private var durationSection: some View {
    Section {
      Stepper(
        value: Binding(
          get: { sketch.lengthInDays },
          set: { newLength in
            sketch.setLength(newLength)
            model.persistSketch(sketch)
          }),
        in: 1...60
      ) {
        Text("^[\(sketch.lengthInDays) day](inflect: true)")
      }
    } header: {
      Text("Duration")
    } footer: {
      Text("How many days the trip runs. Shortening it drops the days past the new end.")
    }
  }

  private var daysSection: some View {
    Section {
      ForEach(dayDesigns) { day in
        dayRow(day)
      }
      .reorderable()
      NavigationLink {
        RangeAssignView(model: model, sketch: $sketch)
      } label: {
        Label("Set a region for specific days…", systemImage: Icon.map.systemName)
      }
    } header: {
      Text("Days")
    } footer: {
      if model.tripRegions.isEmpty {
        Text(
          "This trip has no regions yet. Create them on the Ideas map, then attach them "
          + "with “Attach regions…” to assign them to days here.")
      } else {
        Text("Assign each part of the trip to a region — it scopes that day's ideas and frames its map (ADR-0012).")
      }
      Text("Drag a day to move its stops, summary, region and time zone. Lodging stays with its nights.")
    }
  }

  private var dayDesigns: [TripDayDesign] {
    guard let trip = model.trip else { return [] }
    return TripDayDesign.rows(
      trip: trip, dayRegions: model.allTripDayRegions, dayTimeZones: model.allTripDayTimeZones,
      dayNotes: model.allTripDayNotes, stays: model.plan.stays,
      stops: model.plan.scheduled, now: model.now)
  }

  private func dayRow(_ day: TripDayDesign) -> some View {
    let span = sketch.spans.first { $0.days.contains(day.day) }
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Text(dayLabel(day))
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 4)
        regionMenu(for: day.day, span: span)
        if day.date != nil {
          DayTimeZoneMenu(day: day.day, model: model, defaultZone: defaultTimeZone)
        }
        if day.lock != nil {
          Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(day.lockCaption ?? "Locked day")
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Summary")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("What's this day for?", text: summaryBinding(for: day.day), axis: .vertical)
          .lineLimit(1...3)
          .focused($focusedDay, equals: day.day)
          .submitLabel(.done)
          .onSubmit { commitSummary(for: day.day) }
      }
      if let title = day.stayTitle {
        Label(title, systemImage: Icon.stay.systemName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let lockCaption = day.lockCaption {
        Text(lockCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func regionMenu(for day: Int, span: DaySpan?) -> some View {
    let assigned = model.region(span?.regionID)
    return Menu {
      Picker(
        "Region",
        selection: Binding(
          get: { sketch.spans.first { $0.days.contains(day) }?.regionID },
          set: { newRegionID in
            sketch.assign(newRegionID, toDays: day...day)
            model.persistSketch(sketch)
          })
      ) {
        Text("None").tag(MapRegion.ID?.none)
        ForEach(model.tripRegions) { region in
          Text(region.name).tag(MapRegion.ID?.some(region.id))
        }
      }
      Divider()
      Button {
        if let span { model.addLodging(forSpan: span) }
      } label: {
        Label("Add lodging for these nights", systemImage: Icon.stay.systemName)
      }
      Button {
        model.regionChipTapped()
      } label: {
        Label("Attach regions…", systemImage: Icon.map.systemName)
      }
    } label: {
      HStack(spacing: 5) {
        Icon.map.image.imageScale(.small)
        Text(assigned?.name ?? "Set region").lineLimit(1)
      }
      .font(.subheadline)
      .foregroundStyle(assigned == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
    .buttonStyle(.borderless)
  }

  private func dayLabel(_ day: TripDayDesign) -> String {
    guard let date = day.date else { return "Day \(day.day)" }
    return "Day \(day.day) · \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
  }

  private func summaryBinding(for day: Int) -> Binding<String> {
    Binding(
      get: { summaryDrafts[day] ?? model.dayNote(forDay: day) ?? "" },
      set: { summaryDrafts[day] = $0 })
  }

  private func commitSummary(for day: Int) {
    guard let draft = summaryDrafts.removeValue(forKey: day) else { return }
    model.setDayNote(draft, forDay: day)
  }

  private func commitAllSummaries() {
    let drafts = summaryDrafts
    summaryDrafts.removeAll()
    for day in drafts.keys.sorted() {
      guard let draft = drafts[day] else { continue }
      model.setDayNote(draft, forDay: day)
    }
  }

  private func reorderDays(
    _ difference: ReorderDifference<TripDayDesign.ID, ReorderableSingleCollectionIdentifier>
  ) {
    guard let from = difference.sources.first else { return }
    let to: Int
    switch difference.destination.position {
    case let .before(day): to = day - (from < day ? 1 : 0)
    case .end: to = dayDesigns.count
    }
    guard from != to else { return }

    commitAllSummaries()
    focusedDay = nil
    if let refusal = model.moveDay(DayMove(from: from, to: to)) {
      moveRefusal = refusal
    } else {
      sketch = model.sketch
    }
  }
}

private struct DayDesignDragPayload: Codable, Identifiable, Transferable {
  let id: Int

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .plainText)
  }
}

/// Assign a region to an arbitrary day range — how a span is *split* (giving part of
/// it a different region makes the boundary real). Region menu + two day steppers,
/// applied live and popped. Operates on the whole trip's day range rather than a
/// captured span, so it never goes stale as the sketch recomputes.
private struct RangeAssignView: View {
  let model: TripPlanningModel
  @Binding var sketch: TripSketch
  @Environment(\.dismiss) private var dismiss

  @State private var regionID: MapRegion.ID?
  @State private var fromDay: Int
  @State private var toDay: Int

  init(model: TripPlanningModel, sketch: Binding<TripSketch>) {
    self.model = model
    _sketch = sketch
    _regionID = State(initialValue: model.tripRegions.first?.id)
    _fromDay = State(initialValue: 1)
    _toDay = State(initialValue: sketch.wrappedValue.lengthInDays)
  }

  private var length: Int { sketch.lengthInDays }

  var body: some View {
    Form {
      Section("Region") {
        Picker("Region", selection: $regionID) {
          Text("None").tag(MapRegion.ID?.none)
          ForEach(model.tripRegions) { region in
            Text(region.name).tag(MapRegion.ID?.some(region.id))
          }
        }
        if model.tripRegions.isEmpty {
          Button {
            model.regionChipTapped()
          } label: {
            Label("Attach regions…", systemImage: Icon.map.systemName)
          }
        }
      }
      Section("Days") {
        Stepper(value: $fromDay, in: 1...length) {
          LabeledContent("From", value: "Day \(fromDay)")
        }
        .onChange(of: fromDay) { _, day in
          if toDay < day { toDay = day }
        }
        Stepper(value: $toDay, in: fromDay...length) {
          LabeledContent("To", value: "Day \(toDay)")
        }
      }
      Section {
        Button("Assign") {
          sketch.assign(regionID, toDays: fromDay...toDay)
          model.persistSketch(sketch)
          dismiss()
        }
      }
    }
    .navigationTitle("Region for Days")
    .navigationBarTitleDisplayMode(.inline)
  }
}
