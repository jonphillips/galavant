import Foundation
import GalavantSchema
import SwiftUI

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
    measurement.formatted(
      .measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))
    )
  }
}

extension LeaveBy {
  var text: String {
    switch self {
    case let .clock(date):
      "Leave by \(date.formatted(date: .omitted, time: .shortened))"
    case let .approximate(travelTime, mode):
      "~\(travelTime.formatted(mode: mode))"
    case let .awayBy(travelTime, mode):
      "\(travelTime.formatted(mode: mode)) away"
    }
  }
}
