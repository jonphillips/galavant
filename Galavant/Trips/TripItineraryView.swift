import GalavantSchema
import SwiftUI

/// The trip's Itinerary tab: a "To Be Scheduled" bucket atop the day-by-day
/// layout (day-relative, never dates — docs/trip-time-model.md). Each stop's
/// menu sets/moves its day and time of day. The Add button (in the parent shell)
/// opens the Add-Stop sheet.
struct TripItineraryView: View {
  let model: TripPlanningModel

  var body: some View {
    if model.hasScheduledStops {
      List {
        if !model.toBeScheduledStops.isEmpty {
          Section("To Be Scheduled") {
            ForEach(model.toBeScheduledStops) { resolved in
              PlanningRow(idea: resolved.idea) {
                stopMenu(for: resolved.idea, schedule: resolved.entry.schedule)
              }
            }
          }
        }
        ForEach(model.itinerary) { day in
          Section {
            if day.stops.isEmpty {
              Text("No stops yet")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            } else {
              ForEach(day.stops) { resolved in
                PlanningRow(idea: resolved.idea) {
                  stopMenu(for: resolved.idea, schedule: resolved.entry.schedule)
                }
              }
            }
          } header: {
            Text(dayLabel(day.number, trip: model.trip))
          }
        }
      }
    } else {
      // Shown in place of the list (not overlaid on it) so the empty message
      // sits on its own opaque background instead of floating over day rows.
      ContentUnavailableView {
        Label("Nothing scheduled", systemImage: "calendar")
      } description: {
        Text("Pull ideas onto the shortlist, then tap + to schedule them onto days.")
      } actions: {
        Button("Add a Stop") { model.addStopButtonTapped() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background)
    }
  }

  /// The time-and-lifecycle menu on an itinerary stop: set or move its day, set
  /// its time of day, send it back to the To-Be-Scheduled bucket, skip it, or
  /// return it to the shortlist. (Marking a stop "done" is deliberately absent —
  /// completion is assumed once the trip passes; see docs/BACKLOG.md.)
  private func stopMenu(for idea: Idea, schedule: Schedule) -> some View {
    let placed = schedule.dayNumber != nil
    let day = schedule.dayNumber ?? 1
    return Menu {
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
