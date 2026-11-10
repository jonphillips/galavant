import GalavantSchema
import SwiftUI

struct SectionHeader: View {
  @Environment(AppRouter.self) private var router
  let label: String
  let day: Int?
  let model: TripPlanningModel

  var body: some View {
    if let day {
      HStack(alignment: .top, spacing: 8) {
        Button { model.sketchTapped(focusingDay: day) } label: {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
              Text(label)
              if let region = model.dayRegion(forDay: day) {
                Text("· \(region.name)")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
              if let zone = model.dayTimeZone(forDay: day) {
                let date = model.trip?.date(forDay: day) ?? .now
                Text("· \(zone.abbreviation(for: date) ?? zone.identifier)")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
            if let note = model.dayNote(forDay: day) {
              Text(note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit day \(day)")
        if let region = model.dayRegion(forDay: day) {
          Button {
            router.openGuide(forTrip: model.tripID, regionID: region.id)
          } label: {
            Image(systemName: "book.and.wrench")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Open the Guide for \(region.name)")
        }
      }
    } else {
      Text(label)
    }
  }
}

struct DayTimeZoneMenu: View {
  let day: Int
  let model: TripPlanningModel
  var defaultZone: TimeZone?

  var body: some View {
    let assigned = model.dayTimeZone(forDay: day)
    let defaultAbbreviation = defaultZone?.abbreviation(for: model.trip?.date(forDay: day) ?? .now)
      ?? defaultZone?.identifier
    return Menu {
      Button {
        model.setDayTimeZone(nil, forDay: day)
      } label: {
        if assigned == nil, let defaultAbbreviation {
          Label("Trip default (\(defaultAbbreviation))", systemImage: Icon.checkmark.systemName)
        } else if assigned == nil {
          Icon.checkmark.label("Trip default")
        } else {
          Text(defaultAbbreviation.map { "Trip default (\($0))" } ?? "Trip default")
        }
      }
      Divider()
      ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { identifier in
        Button {
          model.setDayTimeZone(identifier, forDay: day)
        } label: {
          if identifier == assigned?.identifier {
            Label(identifier, systemImage: Icon.checkmark.systemName)
          } else {
            Text(identifier)
          }
        }
      }
    } label: {
      HStack(spacing: 5) {
        Icon.timeOfDay.image
        if let assigned {
          Text(assigned.abbreviation(for: model.trip?.date(forDay: day) ?? .now) ?? assigned.identifier)
            .lineLimit(1)
        }
        Icon.menuDisclosure.image.font(.caption2)
      }
      .font(.subheadline)
      .foregroundStyle(assigned == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
    .buttonStyle(.borderless)
    .textCase(nil)
  }
}
