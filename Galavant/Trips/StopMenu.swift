import GalavantSchema
import SwiftUI

/// The time menu on an itinerary stop: set or move its day, or set its time of day.
/// Shared by the canvas timeline (one focused day) and the full day-by-day itinerary.
struct StopMenu: View {
  let model: TripPlanningModel
  let stop: ResolvedStop

  private var schedule: Schedule { stop.entry.schedule }
  private var isTimed: Bool {
    if case .timed = schedule { return true } else { return false }
  }
  private var calendarLinked: Bool { model.calendarTimeAuthority(for: stop.id) == .linked }

  var body: some View {
    let placed = schedule.dayNumber != nil
    let day = schedule.dayNumber ?? 1
    Menu {
      if placed, !calendarLinked {
        Menu("Time of Day") {
          Button {
            model.setSchedule(.day(day), for: stop.id)
          } label: {
            if schedule.dayPart == nil {
              Icon.checkmark.label("Anytime")
            } else {
              Text("Anytime")
            }
          }
          ForEach(DayPart.allCases) { part in
            Button {
              model.setSchedule(.daypart(day, part), for: stop.id)
            } label: {
              if schedule.dayPart == part {
                Label(part.label, systemImage: Icon.checkmark.systemName)
              } else {
                Label(part.label, systemImage: part.systemImage)
              }
            }
          }
        }
        Button(isTimed ? "Change Time…" : "Set Time…", systemImage: Icon.setTime.systemName) {
          model.editStopTime(stop)
        }
      }
      if calendarLinked {
        Label("Time from Shared Calendar", systemImage: "calendar.badge.checkmark")
      }
      Divider()
      if !calendarLinked, let length = model.trip?.lengthInDays {
        Menu(placed ? "Move to Day" : "Set Day") {
          ForEach(1...length, id: \.self) { n in
            Button {
              model.moveToDay(stop, day: n)
            } label: {
              let title = dayLabel(n, trip: model.trip)
              if placed, n == day {
                Label(title, systemImage: Icon.checkmark.systemName)
              } else {
                Text(title)
              }
            }
          }
        }
      }
    } label: {
      timeLabel
    }
  }

  /// The stop's time, in one vocabulary: an exact clock range reads as a hard
  /// constraint (mono, primary); a daypart is a soft bucket (secondary); a stop
  /// placed on a day with no time-of-day shows a faint clock affordance to set
  /// one (the bare-`.day` "Anytime" word is dropped — it was just noise). An
  /// unplaced stop offers "Set day".
  @ViewBuilder private var timeLabel: some View {
    switch schedule {
    case .timed:
      Text(schedule.display)
        .font(.subheadline.monospaced())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: true, vertical: false)
    case let .daypart(_, part):
      Text(part.label).font(.subheadline).foregroundStyle(.secondary)
    case .day:
      Icon.timeOfDay.image.font(.subheadline).foregroundStyle(.tertiary)
    case .unscheduled:
      Icon.schedule.label("Set day").font(.subheadline)
    }
  }
}
