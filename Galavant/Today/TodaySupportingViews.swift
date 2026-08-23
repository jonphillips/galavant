import Foundation
import GalavantSchema
import SwiftUI
import UIKit

struct TodayTimeline: View {
  let remaining: [TodayProjection.RemainingItem]
  let doneStops: [ResolvedStop]
  let skippedStops: [ResolvedStop]
  let canExecute: Bool
  let planningModel: TripPlanningModel
  let onSelectIdea: (Idea) -> Void
  let thumbnailByIdea: [Idea.ID: Data]

  @State private var isDoneExpanded = false
  @State private var isSkippedExpanded = false

  private var doneCount: Int? {
    remaining.compactMap { item in
      guard case let .done(count) = item else { return nil }
      return count
    }.first
  }

  private var skippedCount: Int? {
    remaining.compactMap { item in
      guard case let .skipped(count) = item else { return nil }
      return count
    }.first
  }

  private var items: [ItineraryItem] {
    remaining.compactMap {
      guard case let .item(item) = $0 else { return nil }
      return item
    }
  }

  private var visibleEndpointIDs: Set<String> {
    let timelineIDs = items.compactMap { item in
      switch item {
      case let .stop(stop): "stop-\(stop.id)"
      case let .checkIn(stay), let .checkOut(stay), let .homeBase(stay): "stay-\(stay.id)"
      case .calendarConstraint, .connector, .nowMarker: nil
      }
    }
    let expandedStops = (isDoneExpanded ? doneStops : [])
      + (isSkippedExpanded ? skippedStops : [])
    let expandedStopIDs = expandedStops.map { "stop-\($0.id)" }
    return Set(timelineIDs + expandedStopIDs)
  }

  private var currentConnectorID: String? {
    let hasNowMarker = items.contains { item in
      if case .nowMarker = item { return true }
      return false
    }
    var isAfterNow = !hasNowMarker
    for item in items {
      if case .nowMarker = item {
        isAfterNow = true
        continue
      }
      guard isAfterNow, case .connector = item else { continue }
      return item.id
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("REMAINING")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .tracking(1.1)

      VStack(alignment: .leading, spacing: 0) {
        if let doneCount {
          outcomeDisclosure(
            title: "Done · \(doneCount)",
            accessibilityLabel: "Done, \(doneCount) completed",
            systemImage: "checkmark.circle.fill",
            isExpanded: $isDoneExpanded,
            stops: doneStops)
        }
        if let skippedCount {
          outcomeDisclosure(
            title: "Skipped · \(skippedCount)",
            accessibilityLabel: "Skipped, \(skippedCount)",
            systemImage: "forward.end.circle.fill",
            isExpanded: $isSkippedExpanded,
            stops: skippedStops)
        }

        ForEach(items) { item in
          TodayTimelineRow(
            item: item,
            canExecute: canExecute,
            planningModel: planningModel,
            hasVisibleOrigin: {
              guard case let .connector(connector) = item else { return true }
              return visibleEndpointIDs.contains(connector.from.id)
            }(),
            isCurrentConnector: item.id == currentConnectorID,
            onSelectIdea: onSelectIdea,
            thumbnailByIdea: thumbnailByIdea)
        }
      }
      .padding(16)
      .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }

  @ViewBuilder
  private func outcomeDisclosure(
    title: String,
    accessibilityLabel: String,
    systemImage: String,
    isExpanded: Binding<Bool>,
    stops: [ResolvedStop]
  ) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded.wrappedValue.toggle()
      }
    } label: {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 0)
        Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.bold))
      }
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
    .accessibilityHint("Shows the stops in this group.")
    .padding(.bottom, isExpanded.wrappedValue ? 8 : 12)

    if isExpanded.wrappedValue {
      ForEach(stops) { stop in
        TodayTimelineRow(
          item: .stop(stop),
          canExecute: canExecute,
          planningModel: planningModel,
          hasVisibleOrigin: true,
          isCurrentConnector: false,
          onSelectIdea: onSelectIdea,
          thumbnailByIdea: thumbnailByIdea)
      }
    }
  }
}

private struct TodayTimelineRow: View {
  let item: ItineraryItem
  let canExecute: Bool
  let planningModel: TripPlanningModel
  let hasVisibleOrigin: Bool
  let isCurrentConnector: Bool
  let onSelectIdea: (Idea) -> Void
  let thumbnailByIdea: [Idea.ID: Data]

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      timelineGuide
      content
        .padding(.bottom, 16)
      Spacer(minLength: 0)
      if canExecute, case let .stop(stop) = item {
        stopMenu(for: stop)
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var timelineGuide: some View {
    VStack(spacing: 0) {
      switch item {
      case .nowMarker:
        Circle()
          .fill(.tint)
          .frame(width: 10, height: 10)
          .overlay { Circle().stroke(.background, lineWidth: 2) }
      case .connector:
        Image(systemName: "arrow.down")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 18)
      case let .stop(stop):
        let isDone = stopIsDone(stop)
        if canExecute {
          Button {
            Task {
              switch stop.entry.outcome {
              case .done:
                await planningModel.uncompleteStop(stop.id)
              case .pending, .skipped:
                await planningModel.completeStop(stop.id)
              }
            }
          } label: {
            Image(systemName: isDone
              ? "checkmark.circle.fill"
              : "circle")
              .font(.title3)
              .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(isDone ? "Undo done" : "Mark done")
        } else {
          Circle()
            .fill(.secondary)
            .frame(width: 8, height: 8)
            .frame(height: 18)
        }
      default:
        Circle()
          .fill(.secondary)
          .frame(width: 8, height: 8)
          .frame(height: 18)
      }
      Rectangle()
        .fill(.quaternary)
        .frame(width: 2, height: 30)
    }
    .frame(width: 18)
  }

  @ViewBuilder private var content: some View {
    switch item {
    case let .stop(stop):
      if let idea = stop.idea {
        Button { onSelectIdea(idea) } label: {
          stopSummary(stop)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint("Shows stop details.")
      } else {
        stopSummary(stop)
      }
    case let .connector(connector):
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          if !hasVisibleOrigin {
            Text("From \(connector.from.title)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(connector.travelTime?.formatted(mode: connector.mode) ?? "Travel time")
            .font(.subheadline.weight(.medium))
          Text("to \(connector.to.title)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if showsDirections(for: connector) {
          directionsButton(for: connector)
        }
      }
      .foregroundStyle(.secondary)
    case .nowMarker:
      Text("Now")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .padding(.top, 1)
    case let .checkIn(stay):
      TodayTimelineEvent(
        title: "Check in", detail: stay.content.title,
        display: stay.stay.checkInDisplay)
    case let .checkOut(stay):
      TodayTimelineEvent(
        title: "Check out", detail: stay.content.title,
        display: stay.stay.checkOutDisplay)
    case let .homeBase(stay):
      TodayTimelineEvent(title: "Home base", detail: stay.content.title)
    case let .calendarConstraint(constraint):
      TodayTimelineEvent(
        title: constraint.title,
        detail: constraint.displayTime ?? constraint.startTime ?? "All day")
    }
  }

  private func stopSummary(_ stop: ResolvedStop) -> some View {
    HStack(alignment: .top, spacing: 10) {
      if let ideaID = stop.idea?.id,
        let thumbnail = thumbnailByIdea[ideaID],
        let image = UIImage(data: thumbnail) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: 52, height: 52)
          .background(Color(.secondarySystemFill))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
      } else {
        Image(systemName: stop.idea?.kind?.systemImage ?? "mappin.and.ellipse")
          .foregroundStyle(.secondary)
          .frame(width: 52, height: 52)
          .background(Color(.secondarySystemFill))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(stop.content.title).font(.body.weight(.semibold))
        Text(stop.entry.schedule.display).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func stopIsDone(_ stop: ResolvedStop) -> Bool {
    if case .done = stop.entry.outcome { return true }
    return false
  }

  private func stopMenu(for stop: ResolvedStop) -> some View {
    Menu {
      switch stop.entry.outcome {
      case .done:
        Button("Undo done", systemImage: "arrow.uturn.backward") {
          Task { await planningModel.uncompleteStop(stop.id) }
        }
      case .skipped:
        Button("Unskip", systemImage: "arrow.uturn.backward") {
          Task { await planningModel.unskipStop(stop.id) }
        }
      case .pending:
        Button("Skip", systemImage: "forward.end") {
          Task { await planningModel.skipStop(stop.id) }
        }
        Divider()
        Button("Do later today", systemImage: "clock.arrow.2.circlepath") {
          Task { await planningModel.deferStopToLaterToday(stop.id) }
        }
        if stop.entry.dayNumber != planningModel.plan.lengthInDays {
          Button("Do tomorrow", systemImage: "sunrise") {
            Task { await planningModel.deferStopToTomorrow(stop.id) }
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
        .frame(width: 32, height: 32)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Actions for \(stop.content.title)")
  }

  private func directionsButton(for connector: TravelConnector) -> some View {
    Button {
      openInMaps(connector: connector)
    } label: {
      Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
        .frame(width: 32, height: 32)
    }
    .modifier(TodayDirectionsButtonStyle(
      emphasis: isCurrentConnector ? .prominent : .quiet))
    .accessibilityLabel("Directions")
    .accessibilityHint("Opens directions in Apple Maps.")
  }

  private func showsDirections(for connector: TravelConnector) -> Bool {
    guard connector.mode == .walking, let travelTime = connector.travelTime else { return true }
    return travelTime.seconds >= 60
  }
}

private struct TodayTimelineEvent: View {
  let title: String
  let detail: String
  var display: TripStay.CheckDisplay? = nil

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          Text(title).font(.body.weight(.semibold))
          if let official = display?.officialParenthetical {
            Text("(\(official))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let trailing = display?.trailing {
        Text(trailing)
          .font(.body.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }
}
