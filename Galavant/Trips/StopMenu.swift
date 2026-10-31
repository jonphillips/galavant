import GalavantSchema
import SwiftUI

/// The time menu on an itinerary stop: set or move its day, or set its time of day.
/// The same actions are available from the row's context menu.
struct StopMenu: View {
  let model: TripPlanningModel
  let stop: ResolvedStop
  let booking: ResolvedBooking?

  private var schedule: Schedule { stop.entry.schedule }

  var body: some View {
    Menu {
      StopMenuActions(model: model, stop: stop, booking: booking)
    } label: {
      timeLabel
    }
  }

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
      Icon.timeOfDay.image.font(.subheadline).foregroundStyle(.tertiary)
    }
  }
}

struct StopMenuActions: View {
  let model: TripPlanningModel
  let stop: ResolvedStop
  let booking: ResolvedBooking?

  private var schedule: Schedule { stop.entry.schedule }
  private var isTimed: Bool {
    if case .timed = schedule { return true } else { return false }
  }
  private var calendarLinked: Bool { model.calendarTimeAuthority(for: stop.id) == .linked }

  var body: some View {
    let placed = schedule.dayNumber != nil
    let day = schedule.dayNumber ?? 1
    Group {
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
      if let booking, let nextBookingStatus = BookingStatus.quickAction(for: booking) {
        Button(nextBookingStatus == .booked ? "Mark Booked" : "Mark To Book", systemImage: "ticket") {
          model.toggleBookingStatus(for: stop)
        }
      }
      if case .day = schedule {
        // Non-drag intra-day reorder (ADR-0033 Slice 4). Only a bare `.day`
        // Anytime stop carries a hand-order; timed/dayparted stops are pinned by
        // their schedule. This remains the reliable reorder path for those stops.
        Divider()
        Button("Move Earlier in Day", systemImage: Icon.moveEarlier.systemName) {
          model.moveStopEarlier(stop)
        }
        .disabled(!model.canMoveStopEarlier(stop))
        Button("Move Later in Day", systemImage: Icon.moveLater.systemName) {
          model.moveStopLater(stop)
        }
        .disabled(!model.canMoveStopLater(stop))
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
    }
  }
}
