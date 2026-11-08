import GalavantSchema
import SwiftUI

struct RegionGuideTripLensView: View {
  let lens: GuideTripLens
  let model: RegionGuideModel
  let horizontalSizeClass: UserInterfaceSizeClass?
  let onSelectSlot: (Int, Meal) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Menu {
          ForEach([lens.trip] + lens.otherTrips) { trip in
            Button(trip.name) { model.tripSelected(trip.id) }
          }
        } label: {
          Label(lens.trip.name, systemImage: "airplane")
            .font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        Spacer()
        Text(lens.heading).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Button { model.lensFoldButtonTapped() } label: {
          Image(systemName: model.lensFolded ? "chevron.down" : "chevron.up")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.lensFolded ? "Expand trip lens" : "Fold trip lens")
      }
      if !model.lensFolded {
        switch lens.body {
        case let .meals(days): mealDaysView(days)
        case let .nights(runs): nightRunsView(runs)
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private func mealDaysView(_ days: [GuideTripLens.MealDay]) -> some View {
    if horizontalSizeClass == .regular {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Day").frame(width: 80, alignment: .leading)
          Text("Lunch").frame(maxWidth: .infinity, alignment: .leading)
          Text("Dinner").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.bold()).foregroundStyle(.secondary)
        ForEach(days) { day in
          HStack(alignment: .top, spacing: 8) {
            Text(day.weekday?.shortLabel ?? "Day \(day.day)").font(.caption.bold()).frame(width: 80, alignment: .leading)
            mealCell(day.lunch, day: day.day, meal: .lunch, label: "Lunch")
            mealCell(day.dinner, day: day.day, meal: .dinner, label: "Dinner")
          }
          if !day.alsoThatDay.isEmpty { alsoThatDay(day.alsoThatDay).padding(.leading, 88) }
        }
      }
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 8) {
          ForEach(days) { day in
            VStack(alignment: .leading, spacing: 6) {
              Text(day.weekday?.shortLabel ?? "Day \(day.day)").font(.caption.bold())
              mealCell(day.lunch, day: day.day, meal: .lunch, label: "L")
              mealCell(day.dinner, day: day.day, meal: .dinner, label: "D")
              if !day.alsoThatDay.isEmpty { alsoThatDay(day.alsoThatDay) }
            }
            .frame(width: 155, alignment: .leading)
            .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
    }
  }

  private func alsoThatDay(_ stops: [GuideTripLens.SlotStop]) -> some View {
    Text("Also: \(stops.map(\.title).joined(separator: ", "))")
      .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
  }

  private func nightRunsView(_ runs: [GuideTripLens.NightRun]) -> some View {
    Group {
      if horizontalSizeClass == .regular {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(runs.enumerated()), id: \.offset) { _, run in nightRunView(run) }
        }
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
              nightRunView(run).padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func nightRunView(_ run: GuideTripLens.NightRun) -> some View {
    switch run {
    case let .open(nights):
      Text("Open · Night \(nights.lowerBound)\(nights.lowerBound == nights.upperBound ? "" : "–\(nights.upperBound)")")
        .font(.subheadline).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])))
    case let .stay(_, ideaID, title, booked, nights):
      Button { model.tripStopTapped(ideaID) } label: {
        Label("\(title) · Night \(nights.lowerBound)\(nights.lowerBound == nights.upperBound ? "" : "–\(nights.upperBound)")",
          systemImage: booked ? "checkmark.circle.fill" : "bed.double")
      }.buttonStyle(.plain)
    }
  }

  @ViewBuilder private func mealCell(_ cell: GuideTripLens.MealCell, day: Int, meal: Meal, label: String) -> some View {
    switch cell {
    case .open:
      Button { onSelectSlot(day, meal) } label: {
        Text("\(label) · Open").font(.caption).padding(.horizontal, 7).padding(.vertical, 5)
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])))
      }.buttonStyle(.plain)
    case let .filled(stops):
      if let stop = stops.first {
        Button { onSelectSlot(day, meal) } label: {
          HStack(spacing: 4) {
            if stop.isBooked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            Text("\(label) · \(stop.title)\(stop.optionCount > 1 ? " · \(stop.optionCount) options" : "")\(stops.count > 1 ? " +\(stops.count - 1)" : "")")
              .italic(stop.isFreeform).lineLimit(1)
          }.font(.caption).padding(.horizontal, 7).padding(.vertical, 5)
            .background(stop.optionCount > 1 ? Color.orange.opacity(0.14) : Color.green.opacity(stop.isBooked ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
      }
    }
  }
}
