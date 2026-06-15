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

  /// The whole trip: the dayless bucket, then every day. Drag a stop into another
  /// day's section to move it there, or into "To Be Scheduled" to unplace it (the
  /// `StopMenu` covers the same moves by tap). Built on the iOS 27 reorder-container
  /// API (`reorderable(collectionID:)` per section + `reorderContainer(for:in:)`):
  /// the whole section is the drop zone and SwiftUI routes the move by the
  /// destination section's id. Within-day order is the schedule's to decide (stops
  /// auto-sort by time), so we use only `destination.collectionID`, not its
  /// position — this is purely cross-section.
  private var fullItinerary: some View {
    List {
      if !model.toBeScheduledStops.isEmpty {
        Section("To Be Scheduled") {
          ForEach(model.toBeScheduledStops) { resolved in stopRow(resolved) }
            .reorderable(collectionID: ItinerarySection.bucket)
        }
      }
      ForEach(model.itinerary) { day in
        Section(dayLabel(day.number, trip: model.trip)) {
          // The reorderable ForEach declares the section's collection even when
          // empty, so a stop can be dropped onto a day that has none yet.
          ForEach(day.stops) { resolved in stopRow(resolved) }
            .reorderable(collectionID: ItinerarySection.day(day.number))
          if day.stops.isEmpty {
            Text("No stops yet — drag one here")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .reorderContainer(for: TripPlanningModel.Resolved.self, in: ItinerarySection.self) {
      difference in
      model.moveStops(difference.sources, to: difference.destination.collectionID)
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
    .id(resolved.id)
  }
}

/// Which itinerary section a reorder collection belongs to — the dayless bucket
/// or a numbered day. Used as the reorder container's `collectionID` so a dropped
/// stop routes to the right `moveStop`/`moveStopToBeScheduled`.
enum ItinerarySection: Hashable {
  case bucket
  case day(Int)
}
