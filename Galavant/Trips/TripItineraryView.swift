import GalavantSchema
import SwiftUI

/// The itinerary as a timeline (day-relative, never dates — docs/trip-time-model.md).
/// In the trip canvas's bottom sheet it shows one **focused day** (the day chip's
/// lens); with no focus it shows the whole trip — a "To Be Scheduled" bucket atop
/// the day-by-day layout. Each row taps to select its stop (the shared canvas
/// selection) and carries the `StopMenu` to set/move its day and time.
struct TripItineraryView: View {
  let model: TripPlanningModel
  /// When set, render only this day's stops (the canvas day lens). Nil = the
  /// whole trip.
  var focusedDay: Int?

  var body: some View {
    ScrollViewReader { proxy in
      content
        // Selecting a stop on the map scrolls the matching row into view (the
        // map→list half of the shared selection; list→map is the tap below).
        .onChange(of: model.canvasSelectedStopID) { _, id in
          guard let id else { return }
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }
  }

  @ViewBuilder private var content: some View {
    if let day = focusedDay {
      focusedDayList(day)
    } else if model.hasScheduledStops {
      fullItinerary
    } else {
      emptyState
    }
  }

  /// One day's stops, for the canvas's day lens.
  private func focusedDayList(_ day: Int) -> some View {
    let stops = model.canvasDays.first { $0.number == day }?.stops ?? []
    return List {
      Section {
        if stops.isEmpty {
          Text("No stops on this day yet")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(stops) { resolved in stopRow(resolved) }
        }
      } header: {
        Text(dayLabel(day, trip: model.trip))
      }
    }
  }

  /// The whole trip: the dayless bucket, then every day. Drag a stop onto another
  /// day's header to move it there, or onto "To Be Scheduled" to unplace it (the
  /// `StopMenu` covers the same moves by tap). Within-day order is the schedule's
  /// to decide (stops auto-sort by time), so this is purely cross-section.
  private var fullItinerary: some View {
    List {
      if !model.toBeScheduledStops.isEmpty {
        Section {
          ForEach(model.toBeScheduledStops) { resolved in stopRow(resolved) }
        } header: {
          StopDropHeader(title: "To Be Scheduled") { stop in
            model.moveStopToBeScheduled(stop.stopID)
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
            ForEach(day.stops) { resolved in stopRow(resolved) }
          }
        } header: {
          StopDropHeader(title: dayLabel(day.number, trip: model.trip)) { stop in
            model.moveStop(stop.stopID, toDay: day.number)
          }
        }
      }
    }
  }

  private var emptyState: some View {
    // Shown in place of the list (not overlaid on it) so the empty message sits
    // on its own opaque background instead of floating over day rows.
    ContentUnavailableView {
      Icon.calendar.label("Nothing scheduled")
    } description: {
      Text("Pull ideas onto the shortlist, then tap + to schedule them onto days.")
    } actions: {
      Button("Add a Stop") { model.addStopButtonTapped() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  /// A stop row: the idea, an info button to its detail, its `StopMenu`,
  /// tap-to-select (the shared canvas selection), and a tint when it's selected.
  /// Row-tap stays selection here (the map↔list link); the info button is its own
  /// hit target, so it opens detail without also selecting.
  private func stopRow(_ resolved: TripPlanningModel.Resolved) -> some View {
    PlanningRow(idea: resolved.idea) {
      HStack(spacing: 14) {
        Button { model.showDetail(resolved.idea) } label: {
          Icon.info.image.foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        StopMenu(model: model, idea: resolved.idea, schedule: resolved.entry.schedule)
      }
    }
    .listRowBackground(
      model.canvasSelectedStopID == resolved.id ? Color.accentColor.opacity(0.12) : nil
    )
    .contentShape(Rectangle())
    .onTapGesture { model.selectStop(resolved.id) }
    // Drag this stop onto another day's header (or the bucket) to move it.
    .draggable(StopTransfer(stopID: resolved.id))
    .id(resolved.id)
  }
}

/// A day / bucket section header that accepts a dragged stop: dropping one here
/// moves it onto that day (or back to "To Be Scheduled"). Highlights while a stop
/// hovers so the drop target reads. Lives at file scope for its own `@State`.
private struct StopDropHeader: View {
  let title: String
  let onDrop: (StopTransfer) -> Void
  @State private var targeted = false

  var body: some View {
    Text(title)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .dropDestination(for: StopTransfer.self) { stops, _ in
        guard let stop = stops.first else { return false }
        onDrop(stop)
        return true
      } isTargeted: { targeted = $0 }
      .background(
        targeted ? Color.accentColor.opacity(0.15) : .clear,
        in: RoundedRectangle(cornerRadius: 6))
  }
}
