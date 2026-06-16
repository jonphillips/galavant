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
    } else if model.plan.hasScheduledStops {
      fullItinerary
    } else {
      emptyState
    }
  }

  /// One day's stops, for the canvas's day lens.
  private func focusedDayList(_ day: Int) -> some View {
    let stops = model.plan.itinerary.first { $0.number == day }?.stops ?? []
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

  /// The whole trip: the dayless bucket, then every day. (Dragging stops between
  /// days is parked — List drag-and-drop times out on Xcode 27 beta 1; the
  /// `StopMenu`'s Move-to-Day / To-Be-Scheduled covers it. See docs/KNOWN-ISSUES.md.)
  private var fullItinerary: some View {
    List {
      if !model.plan.toBeScheduled.isEmpty {
        Section("To Be Scheduled") {
          ForEach(model.plan.toBeScheduled) { resolved in stopRow(resolved) }
        }
      }
      ForEach(model.plan.itinerary) { day in
        Section {
          if day.stops.isEmpty {
            Text("No stops yet")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
          } else {
            ForEach(day.stops) { resolved in stopRow(resolved) }
          }
        } header: {
          Text(dayLabel(day.number, trip: model.trip))
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
  private func stopRow(_ resolved: ResolvedStop) -> some View {
    PlanningRow(idea: resolved.idea, subtitle: .category) {
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
    .id(resolved.id)
  }
}
