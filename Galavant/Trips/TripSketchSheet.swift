import GalavantSchema
import SwiftUI

/// Sketch the shape of a trip before any stop exists — how many days, and which
/// region each part of the trip sits in ("four nights Loire, three nights Paris,
/// fly home day 8"). A view + editor over `TripDayRegion` + `Trip.lengthInDays`
/// (ADR-0012), never a new table; the span math is the pure `TripSketch` value type
/// (docs/handoff/trip-sketch-design.md).
///
/// Edits persist live through the model, so a per-span "Add lodging" or the
/// "Attach regions…" hand-off can leave for another editor without losing the
/// region work already done. The working copy is held locally for a responsive UI
/// and re-seeded each time the sheet is opened.
struct TripSketchSheet: View {
  let model: TripPlanningModel
  @State private var sketch: TripSketch
  @Environment(\.dismiss) private var dismiss

  init(model: TripPlanningModel) {
    self.model = model
    _sketch = State(initialValue: model.sketch)
  }

  var body: some View {
    NavigationStack {
      Form {
        durationSection
        daysSection
      }
      .navigationTitle("Shape Trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
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
      ForEach(sketch.spans) { span in
        spanRow(span)
      }
      NavigationLink {
        RangeAssignView(model: model, sketch: $sketch)
      } label: {
        Label("Set a region for specific days…", systemImage: Icon.map.systemName)
      }
    } header: {
      Text("Regions by day")
    } footer: {
      if model.tripRegions.isEmpty {
        Text(
          "This trip has no regions yet. Create them on the Ideas map, then attach them "
          + "with “Attach regions…” to assign them to days here.")
      } else {
        Text("Assign each part of the trip to a region — it scopes that day's ideas and frames its map (ADR-0012).")
      }
    }
  }

  @ViewBuilder private func spanRow(_ span: DaySpan) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(dayRangeLabel(span)).font(.subheadline.weight(.medium))
        Text("^[\(span.dayCount) day](inflect: true)")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let stay = model.stay(overlapping: span) {
          Label(stay.content.title, systemImage: Icon.stay.systemName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      regionMenu(for: span)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        model.addLodging(forSpan: span)
      } label: {
        Label("Add lodging", systemImage: Icon.stay.systemName)
      }
      .tint(.indigo)
    }
  }

  private func regionMenu(for span: DaySpan) -> some View {
    let assigned = model.region(span.regionID)
    return Menu {
      Picker(
        "Region",
        selection: Binding(
          get: { span.regionID },
          set: { newRegionID in
            sketch.assign(newRegionID, toDays: span.days)
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
        model.addLodging(forSpan: span)
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

  /// "Days 1–4" for a span, "Day 5" for a single day.
  private func dayRangeLabel(_ span: DaySpan) -> String {
    span.startDay == span.endDay
      ? "Day \(span.startDay)"
      : "Days \(span.startDay)–\(span.endDay)"
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
