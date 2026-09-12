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
          if model.tripRegions.isEmpty {
            UnassignedRegionChip(model: model)
          } else {
            DayRegionMenu(day: day, model: model)
          }
          if model.showsDayTimeZoneMenu(forDay: day) {
            DayTimeZoneMenu(day: day, model: model)
          }
        }
      }
    }
  }
}
/// The day header's region chip when the trip has no regions attached yet —
/// there's nothing to assign, so the tap routes to Edit Trip's Regions picker
/// instead of opening an empty menu (dogfood brief item 6).
struct UnassignedRegionChip: View {
  let model: TripPlanningModel

  var body: some View {
    Button {
      model.regionChipTapped()
    } label: {
      HStack(spacing: 5) {
        Icon.map.image.imageScale(.medium)
        Text("Set region").lineLimit(1)
      }
      .font(.subheadline)
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
    .buttonStyle(.borderless)
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
