import GalavantSchema
import SwiftUI

/// The time-and-lifecycle menu on an itinerary stop: set or move its day, set its
/// time of day, send it back to the To-Be-Scheduled bucket, skip it, or return it
/// to the shortlist (idea-backed) / remove it (freeform — freeform stops have no
/// shortlist per ADR-0010). (Marking a stop "done" is deliberately absent —
/// completion is assumed once the trip passes; see docs/BACKLOG.md.) Shared by the
/// canvas timeline (one focused day) and the full day-by-day itinerary.
struct StopMenu: View {
  let model: TripPlanningModel
  let stop: ResolvedStop

  private var schedule: Schedule { stop.entry.schedule }
  private var stopID: TripIdea.ID { stop.id }
  private var isFreeform: Bool {
    if case .freeform = stop.content { return true } else { return false }
  }

  var body: some View {
    let placed = schedule.dayNumber != nil
    let day = schedule.dayNumber ?? 1
    Menu {
      if placed {
        Menu("Time of Day") {
          Button {
            model.setSchedule(.day(day), for: stopID)
          } label: {
            if schedule.dayPart == nil {
              Icon.checkmark.label("Anytime")
            } else {
              Text("Anytime")
            }
          }
          ForEach(DayPart.allCases) { part in
            Button {
              model.setSchedule(.daypart(day, part), for: stopID)
            } label: {
              if schedule.dayPart == part {
                Label(part.label, systemImage: Icon.checkmark.systemName)
              } else {
                Label(part.label, systemImage: part.systemImage)
              }
            }
          }
        }
        Button("To Be Scheduled", systemImage: Icon.toBeScheduled.systemName) {
          model.sendToBeScheduled(stopID)
        }
      }
      Divider()
      if let length = model.trip?.lengthInDays {
        Menu(placed ? "Move to Day" : "Set Day") {
          ForEach(1...length, id: \.self) { n in
            Button {
              model.setSchedule(schedule.onDay(n), for: stopID)
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
      Button("Mark Skipped", systemImage: Icon.skip.systemName) { model.markSkipped(stopID) }
      if isFreeform {
        Button("Remove", systemImage: Icon.delete.systemName, role: .destructive) {
          model.remove(stopID)
        }
      } else {
        Button("Move to Shortlist", systemImage: Icon.revert.systemName) {
          model.unschedule(stopID)
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
      Text(schedule.display).font(.subheadline.monospaced()).foregroundStyle(.primary)
    case let .daypart(_, part):
      Text(part.label).font(.subheadline).foregroundStyle(.secondary)
    case .day:
      Icon.timeOfDay.image.font(.subheadline).foregroundStyle(.tertiary)
    case .unscheduled:
      Icon.schedule.label("Set day").font(.subheadline)
    }
  }
}
