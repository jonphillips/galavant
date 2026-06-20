import GalavantSchema
import MapKit
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
    let items = model.plan.itineraryItems(
      forDay: day, travelTimes: model.travelTimes, effectiveModes: model.effectiveModes,
      now: Date.now, tripStartDate: model.trip?.startDate)
    return List {
      Section {
        if items.isEmpty {
          Text("No stops on this day yet")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(items) { item in itineraryRow(item) }
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
        let items = model.plan.itineraryItems(
          forDay: day.number, travelTimes: model.travelTimes, effectiveModes: model.effectiveModes,
          now: Date.now, tripStartDate: model.trip?.startDate)
        Section {
          if items.isEmpty {
            Text("No stops yet")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
          } else {
            ForEach(items) { item in itineraryRow(item) }
          }
        } header: {
          Text(dayLabel(day.number, trip: model.trip))
        }
      }
    }
  }

  private var emptyState: some View {
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

  @ViewBuilder private func itineraryRow(_ item: ItineraryItem) -> some View {
    switch item {
    case .stop(let resolved): stopRow(resolved)
    case .connector(let connector): connectorRow(connector)
    case .nowMarker: nowMarkerRow
    }
  }

  /// A stop row: the stop content, an optional info button (idea-backed only),
  /// its `StopMenu`, tap-to-select (the shared canvas selection), and a tint when
  /// selected. Row-tap is selection only; the info button is its own hit target.
  private func stopRow(_ resolved: ResolvedStop) -> some View {
    PlanningRow(content: resolved.content, subtitle: .category) {
      HStack(spacing: 14) {
        if let idea = resolved.idea {
          Button { model.showDetail(idea) } label: {
            Icon.info.image.foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
        }
        StopMenu(model: model, stop: resolved)
      }
    }
    .listRowBackground(
      model.canvasSelectedStopID == resolved.id ? Color.accentColor.opacity(0.12) : nil
    )
    .contentShape(Rectangle())
    .onTapGesture { model.selectStop(resolved.id) }
    .id(resolved.id)
  }

  /// A "you are here" divider — red line with "Now" label, appears at the current
  /// moment in today's day section. Non-interactive; just orients you on the timeline.
  private var nowMarkerRow: some View {
    HStack(spacing: 8) {
      Rectangle()
        .fill(Color.red)
        .frame(height: 1)
      Text("Now")
        .font(.caption.bold())
        .foregroundStyle(.red)
        .fixedSize()
      Rectangle()
        .fill(Color.red)
        .frame(height: 1)
    }
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    .allowsHitTesting(false)
  }

  /// A compact interstitial row showing the travel time and mode to the next stop.
  /// Tap (long press / context menu) to switch mode or open Apple Maps for that leg.
  private func connectorRow(_ connector: TravelConnector) -> some View {
    HStack(spacing: 5) {
      Image(systemName: connector.mode.systemImageName)
        .imageScale(.small)
        .foregroundStyle(.tertiary)
      if let tt = connector.travelTime {
        Text(tt.formatted(mode: connector.mode))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("…")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
    .contentShape(Rectangle())
    .contextMenu {
      // Mode picker — checkmark on the current mode via Picker-in-menu idiom.
      Picker("Transport", selection: Binding(
        get: { connector.mode },
        set: { model.setMode($0, for: connector.leg) }
      )) {
        ForEach(TransportMode.allCases, id: \.self) { mode in
          Label(mode.label, systemImage: mode.systemImageName).tag(mode)
        }
      }
      Divider()
      Button {
        openInMaps(connector: connector)
      } label: {
        Label("Open in Maps", systemImage: "map")
      }
    }
  }

  /// Hands off to Apple Maps with the connector's from→to pair and chosen mode.
  private func openInMaps(connector: TravelConnector) {
    guard
      let from = model.plan.idea(forStopID: connector.fromStopID),
      let to = model.plan.idea(forStopID: connector.toStopID),
      let fromCoord = from.coordinate,
      let toCoord = to.coordinate
    else { return }
    let source = MKMapItem(
      location: CLLocation(latitude: fromCoord.latitude, longitude: fromCoord.longitude),
      address: nil)
    source.name = from.name
    let dest = MKMapItem(
      location: CLLocation(latitude: toCoord.latitude, longitude: toCoord.longitude),
      address: nil)
    dest.name = to.name
    MKMapItem.openMaps(with: [source, dest], launchOptions: [
      MKLaunchOptionsDirectionsModeKey: connector.mode.mkDirectionsMode
    ])
  }
}
