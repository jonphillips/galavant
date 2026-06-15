import GalavantSchema
import SwiftUI

/// The time-and-lifecycle menu on an itinerary stop: set or move its day, set its
/// time of day, send it back to the To-Be-Scheduled bucket, skip it, or return it
/// to the shortlist. (Marking a stop "done" is deliberately absent — completion is
/// assumed once the trip passes; see docs/BACKLOG.md.) Shared by the canvas
/// timeline (one focused day) and the full day-by-day itinerary.
struct StopMenu: View {
  let model: TripPlanningModel
  let idea: Idea
  let schedule: Schedule

  var body: some View {
    let placed = schedule.dayNumber != nil
    let day = schedule.dayNumber ?? 1
    Menu {
      if let length = model.trip?.lengthInDays {
        Menu(placed ? "Move to Day" : "Set Day") {
          ForEach(1...length, id: \.self) { n in
            Button {
              model.setSchedule(schedule.onDay(n), for: idea)
            } label: {
              let title = dayLabel(n, trip: model.trip)
              if placed, n == day {
                Label(title, systemImage: "checkmark")
              } else {
                Text(title)
              }
            }
          }
        }
      }
      if placed {
        Menu("Time of Day") {
          Button {
            model.setSchedule(.day(day), for: idea)
          } label: {
            if schedule.dayPart == nil {
              Label("Anytime", systemImage: "checkmark")
            } else {
              Text("Anytime")
            }
          }
          ForEach(DayPart.allCases) { part in
            Button {
              model.setSchedule(.daypart(day, part), for: idea)
            } label: {
              if schedule.dayPart == part {
                Label(part.label, systemImage: "checkmark")
              } else {
                Label(part.label, systemImage: part.systemImage)
              }
            }
          }
        }
        Button("To Be Scheduled", systemImage: "calendar.badge.clock") {
          model.sendToBeScheduled(idea)
        }
      }
      Divider()
      Button("Mark Skipped", systemImage: "xmark.circle") { model.markSkipped(idea) }
      Button("Move to Shortlist", systemImage: "arrow.uturn.backward") {
        model.unschedule(idea)
      }
    } label: {
      if placed {
        Text(schedule.display).font(.subheadline).foregroundStyle(.secondary)
      } else {
        Label("Set day", systemImage: "calendar.badge.plus").font(.subheadline)
      }
    }
  }
}
