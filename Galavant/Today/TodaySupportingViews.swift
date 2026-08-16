import Foundation
import GalavantSchema
import SwiftUI

struct TodayTimeline: View {
  let remaining: [TodayProjection.RemainingItem]

  private var earlierCount: Int? {
    guard case let .earlierToday(count) = remaining.first else { return nil }
    return count
  }

  private var items: [ItineraryItem] {
    remaining.compactMap {
      guard case let .item(item) = $0 else { return nil }
      return item
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("REMAINING")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .tracking(1.1)

      VStack(alignment: .leading, spacing: 0) {
        if let earlierCount {
          Label("Earlier today · \(earlierCount)", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
            .accessibilityLabel("Earlier today, \(earlierCount) completed")
        }

        ForEach(items) { item in
          TodayTimelineRow(item: item)
        }
      }
      .padding(16)
      .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }
}

private struct TodayTimelineRow: View {
  let item: ItineraryItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      timelineGuide
      content
        .padding(.bottom, 16)
    }
    .accessibilityElement(children: .combine)
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
      VStack(alignment: .leading, spacing: 3) {
        Text(stop.content.title).font(.body.weight(.semibold))
        Text(stop.entry.schedule.display).font(.caption).foregroundStyle(.secondary)
      }
    case let .connector(connector):
      VStack(alignment: .leading, spacing: 3) {
        Text(connector.travelTime?.formatted(mode: connector.mode) ?? "Travel time")
          .font(.subheadline.weight(.medium))
        Text("to \(connector.to.title)").font(.caption).foregroundStyle(.secondary)
      }
      .foregroundStyle(.secondary)
    case .nowMarker:
      Text("Now")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .padding(.top, 1)
    case let .checkIn(stay):
      TodayTimelineEvent(title: "Check in", detail: stay.content.title)
    case let .checkOut(stay):
      TodayTimelineEvent(title: "Check out", detail: stay.content.title)
    case let .homeBase(stay):
      TodayTimelineEvent(title: "Home base", detail: stay.content.title)
    case let .calendarConstraint(constraint):
      TodayTimelineEvent(title: constraint.title, detail: constraint.startTime ?? "All day")
    }
  }
}

private struct TodayTimelineEvent: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.body.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct TodayTonightCard: View {
  let tonight: TodayProjection.Tonight

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("TONIGHT", systemImage: "moon.stars.fill")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
      Text(tonight.stay.content.title)
        .font(.title3.weight(.semibold))
      Text("Night \(tonight.nightNumber) of \(tonight.totalNights)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct TodayTomorrowCard: View {
  let tomorrow: TodayProjection.Tomorrow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("TOMORROW")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
      Text(tomorrow.dayContext.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .font(.title3.weight(.semibold))
      if let locality = tomorrow.dayContext.locality {
        Label(locality, systemImage: "mappin.and.ellipse")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      if let transfer = tomorrow.transfer {
        Label(
          transfer.travelTime?.formatted(mode: transfer.mode) ?? "Transfer",
          systemImage: transfer.mode.systemImageName)
          .font(.subheadline.weight(.medium))
          .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct TodayWeatherReading {
  let condition: String
  let symbolName: String
  let temperature: String
  let precipitationChance: Double?

  static func ambient(in summary: WeatherSummary) -> Self? {
    if let current = summary.current {
      return Self(
        condition: current.condition,
        symbolName: current.symbolName,
        temperature: temperature(current.temperature),
        precipitationChance: nil)
    }
    if let hourly = summary.hourlyInterval.first {
      return Self(
        condition: hourly.condition,
        symbolName: hourly.symbolName,
        temperature: temperature(hourly.temperature),
        precipitationChance: hourly.precipitationChance)
    }
    if let daily = summary.daily {
      return Self(
        condition: daily.condition,
        symbolName: daily.symbolName,
        temperature: "\(temperature(daily.highTemperature))/\(temperature(daily.lowTemperature))",
        precipitationChance: daily.precipitationChance)
    }
    return nil
  }

  static func destination(in summary: WeatherSummary) -> Self? {
    if let hourly = summary.hourlyInterval.first {
      return Self(
        condition: hourly.condition,
        symbolName: hourly.symbolName,
        temperature: temperature(hourly.temperature),
        precipitationChance: hourly.precipitationChance)
    }
    if let daily = summary.daily {
      return Self(
        condition: daily.condition,
        symbolName: daily.symbolName,
        temperature: "\(temperature(daily.highTemperature))/\(temperature(daily.lowTemperature))",
        precipitationChance: daily.precipitationChance)
    }
    return nil
  }

  private static func temperature(_ measurement: Measurement<UnitTemperature>) -> String {
    measurement.formatted(.measurement(width: .narrow, usage: .weather))
  }
}

extension LeaveBy {
  var text: String {
    switch self {
    case let .clock(date):
      "Leave by \(date.formatted(date: .omitted, time: .shortened))"
    case let .approximate(travelTime):
      "~\(travelTime.formatted(mode: .driving))"
    case let .awayBy(travelTime):
      "\(travelTime.formatted(mode: .driving)) away"
    }
  }
}
