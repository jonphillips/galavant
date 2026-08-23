import Foundation
import GalavantSchema
import MapKit
import SwiftUI
import UIKit

enum TodayDirectionsEmphasis {
  case prominent
  case bordered
  case quiet
}

struct TodayDirectionsButtonStyle: ViewModifier {
  let emphasis: TodayDirectionsEmphasis

  @ViewBuilder
  func body(content: Content) -> some View {
    switch emphasis {
    case .prominent:
      content.buttonStyle(.borderedProminent)
    case .bordered:
      content.buttonStyle(.bordered)
    case .quiet:
      content.buttonStyle(.borderless)
    }
  }
}

/// The on-the-ground iPhone projection of one dated trip. This deliberately
/// receives the existing planning model rather than owning persistence or a
/// competing itinerary model.
struct TodayView: View {
  let planningModel: TripPlanningModel

  @Environment(\.dismiss) private var dismiss
  @State private var model = TodayModel()
  /// The day the user has stepped to. `nil` means "follow the live day".
  @State private var selectedDay: Int?
  @State private var detailIdea: Idea?

  private static let leaveByBuffer: TimeInterval = 10 * 60

  private var tripStartDate: Date? { planningModel.trip?.startDate }
  private var dayCount: Int { planningModel.plan.lengthInDays }

  /// The trip day the real clock is on, or `nil` when the trip isn't underway.
  private var liveDay: Int? {
    guard let tripStartDate else { return nil }
    return TodayProjection.tripDay(
      containing: model.now, tripStartDate: tripStartDate, in: planningModel.plan)
  }

  /// The day currently shown: an explicit selection, else the live day, else day 1.
  private var currentDay: Int? {
    selectedDay ?? liveDay ?? (dayCount >= 1 ? 1 : nil)
  }

  /// We are previewing whenever the shown day isn't the live day (including any day
  /// at all when the trip isn't underway).
  private var isPreviewing: Bool {
    guard let currentDay else { return false }
    return currentDay != liveDay
  }

  /// The instant to render: the live clock when live, otherwise the start of the
  /// previewed day (Jon's decision — a morning-of view of the whole day).
  private var renderNow: Date {
    guard isPreviewing, let currentDay, let tripStartDate,
      let start = TodayProjection.startOfTripDay(currentDay, tripStartDate: tripStartDate)
    else { return model.now }
    return start
  }

  /// The projection is rendered at the start of a previewed day, so its next
  /// anchor is that day's forecast. Do not request weather for a completed day;
  /// WeatherKit bounds future requests naturally.
  private var activeWeatherAnchor: WeatherAnchor? {
    guard let liveDay, let currentDay else { return projection?.next?.weatherAnchor }
    return currentDay >= liveDay ? projection?.next?.weatherAnchor : nil
  }

  private var showsDayStepper: Bool { tripStartDate != nil && dayCount >= 1 }

  private func step(_ delta: Int) {
    let current = currentDay ?? 1
    selectedDay = min(max(1, current + delta), dayCount)
  }

  private var projection: TodayProjection? {
    guard let tripStartDate else { return nil }
    return TodayProjection.resolve(
      from: planningModel.plan,
      now: renderNow,
      tripStartDate: tripStartDate,
      travelTimes: planningModel.travelTimes,
      effectiveModes: planningModel.effectiveModes,
      leaveByBuffer: Self.leaveByBuffer)
  }

  /// `TodayProjection.Next` intentionally stays focused on the render model.
  /// The existing itinerary stream still owns the connector needed for the one
  /// shared Apple Maps handoff.
  private var nextConnector: TravelConnector? {
    guard
      let projection,
      let tripStartDate = planningModel.trip?.startDate,
      let nextID = projection.next?.item.id
    else { return nil }
    return planningModel.plan.itineraryItems(
      forDay: projection.dayContext.dayNumber,
      travelTimes: planningModel.travelTimes,
      effectiveModes: planningModel.effectiveModes,
      now: renderNow,
      tripStartDate: tripStartDate,
      stays: planningModel.plan.stays(coveringDay: projection.dayContext.dayNumber))
      .compactMap { item -> TravelConnector? in
        guard case let .connector(connector) = item, connector.to.id == nextID else { return nil }
        return connector
      }
      .first
  }

  private var nextIdeaID: Idea.ID? {
    guard let next = projection?.next, case let .stop(stop) = next.item else { return nil }
    return stop.idea?.id
  }

  private var displayImageIdeaIDs: [Idea.ID] {
    var ideaIDs: [Idea.ID] = []
    if let nextIdeaID { ideaIDs.append(nextIdeaID) }
    if let detailIdea, !ideaIDs.contains(detailIdea.id) {
      ideaIDs.append(detailIdea.id)
    }
    return ideaIDs
  }

  var body: some View {
    NavigationStack {
      Group {
        if let projection {
          today(projection)
        } else if tripStartDate == nil {
          ContentUnavailableView(
            "Today is not available",
            systemImage: "calendar.badge.clock",
            description: Text("Set this trip’s start date before using its Today view."))
        } else {
          ContentUnavailableView(
            "No days planned yet",
            systemImage: "calendar.badge.clock",
            description: Text("Add itinerary days to preview this trip’s Today view."))
        }
      }
      .navigationTitle("Today")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        if showsDayStepper {
          ToolbarItemGroup(placement: .bottomBar) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
              .disabled((currentDay ?? 1) <= 1)
            Spacer()
            HStack(spacing: 8) {
              Text("Day \(currentDay ?? 1) of \(dayCount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
              if isPreviewing {
                Text("PREVIEW")
                  .font(.caption2.weight(.bold))
                  .tracking(0.5)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(.tint.opacity(0.15), in: Capsule())
                  .foregroundStyle(.tint)
              }
            }
            Spacer()
            Button { step(+1) } label: { Image(systemName: "chevron.right") }
              .disabled((currentDay ?? 1) >= dayCount)
          }
        }
      }
    }
    .task { await model.runClock() }
    .task(id: activeWeatherAnchor) {
      await model.loadWeather(for: activeWeatherAnchor)
    }
    .task(id: displayImageIdeaIDs) {
      await model.loadDisplayImages(displayImageIdeaIDs)
    }
    .sheet(item: $detailIdea) { idea in
      NavigationStack {
        IdeaDetailView(
          idea: idea,
          tagNames: planningModel.tagNames(for: idea),
          interests: planningModel.interests(for: idea),
          evaluations: planningModel.evaluations(for: idea),
          stopContext: planningModel.stopContext(for: idea),
          headerImage: model.displayImageData(forIdea: idea.id)
            ?? model.thumbnail(forIdea: idea.id))
          .navigationTitle(idea.name)
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  private func today(_ projection: TodayProjection) -> some View {
    let thumbnailByIdea = model.thumbnailByIdea

    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        TodayDayHeader(
          context: projection.dayContext,
          progress: projection.progress,
          canExecute: !isPreviewing,
          weather: model.weather)

        if let next = projection.next {
          TodayNextHero(
            next: next,
            connector: nextConnector,
            canExecute: !isPreviewing,
            planningModel: planningModel,
            onSelectIdea: { detailIdea = $0 },
            weather: model.weather,
            thumbnailByIdea: thumbnailByIdea,
            displayImage: model.displayImage(forIdea: nextIdeaID))
        } else {
          TodayNoNextCard()
        }

        let timeline = isPreviewing
          ? projection.remaining.filter {
              if case .item(.nowMarker) = $0 { return false }
              return true
            }
          : projection.remaining
        if !timeline.isEmpty {
          TodayTimeline(
            remaining: timeline,
            doneStops: projection.doneStops,
            skippedStops: projection.skippedStops,
            canExecute: !isPreviewing,
            planningModel: planningModel,
            onSelectIdea: { detailIdea = $0 },
            thumbnailByIdea: thumbnailByIdea)
        }

        if let tonight = projection.tonight {
          TodayTonightCard(tonight: tonight)
        }

        if let tomorrow = projection.tomorrow {
          TodayTomorrowCard(tomorrow: tomorrow)
        }
      }
      .padding(20)
    }
    .background(Color(.systemGroupedBackground))
  }
}
