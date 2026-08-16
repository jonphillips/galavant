#if DEBUG
import Dependencies
import GalavantSchema
import SwiftUI

/// DEBUG-only harness to exercise the Slice-2 `WeatherClient` on a real device
/// before the Slice-3 Today screen consumes it. Compiled out of release builds.
/// Reachable from Settings ▸ Developer ▸ Weather Test. Live WeatherKit needs a
/// real device — the simulator returns the canned `previewValue` summary.
@Observable
final class WeatherDebugModel {
  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient

  // Apple Park — a known, stable coordinate for a repeatable fetch.
  private let coordinate = WeatherAnchor.Coordinate(latitude: 37.3349, longitude: -122.0090)

  var granularity: WeatherAnchor.Granularity = .current
  var isLoading = false
  var report: String?
  var failure: String?
  var summary: WeatherSummary?

  @MainActor
  func fetchTapped() async {
    isLoading = true
    report = nil
    failure = nil
    summary = nil
    defer { isLoading = false }

    // One window that serves all three paths: `.current` ignores it, `.daily`
    // reads its reference date, `.hourlyInterval` reads its interval.
    let window = WeatherAnchor.TimeWindow.interval(DateInterval(start: .now, duration: 3 * 60 * 60))
    do {
      let summary = try await weatherClient.forecast(coordinate, window, granularity)
      self.summary = summary
      report = Self.describe(summary)
    } catch {
      failure = String(describing: error)
    }
  }

  private static func describe(_ summary: WeatherSummary) -> String {
    var lines: [String] = []
    if let current = summary.current {
      lines.append("current: \(current.condition) \(temp(current.temperature)) (feels \(temp(current.apparentTemperature)))")
    }
    if let daily = summary.daily {
      lines.append("daily: \(daily.condition) ↑\(temp(daily.highTemperature)) ↓\(temp(daily.lowTemperature)) precip \(percent(daily.precipitationChance))")
    }
    if let first = summary.hourlyInterval.first {
      lines.append("hourly: \(summary.hourlyInterval.count) pts, first \(first.condition) \(temp(first.temperature)) precip \(percent(first.precipitationChance))")
    }
    if let alert = summary.alert {
      lines.append("alert: \(alert.severity) — \(alert.summary)")
    }
    lines.append("expires: \(summary.expiration.formatted(date: .abbreviated, time: .shortened))")
    lines.append("attribution: \(summary.attribution.serviceName)")
    return lines.joined(separator: "\n")
  }

  private static func temp(_ measurement: Measurement<UnitTemperature>) -> String {
    "\(measurement.value.formatted(.number.precision(.fractionLength(0))))\(measurement.unit.symbol)"
  }

  private static func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
  }
}

struct WeatherDebugView: View {
  @State private var model = WeatherDebugModel()

  var body: some View {
    Form {
      Section {
        Picker("Granularity", selection: $model.granularity) {
          Text("Current").tag(WeatherAnchor.Granularity.current)
          Text("Daily").tag(WeatherAnchor.Granularity.daily)
          Text("Hourly interval").tag(WeatherAnchor.Granularity.hourlyInterval)
        }
        Button {
          Task { await model.fetchTapped() }
        } label: {
          if model.isLoading {
            ProgressView()
          } else {
            Text("Fetch weather for Apple Park")
          }
        }
        .disabled(model.isLoading)
      } footer: {
        Text("Live WeatherKit needs a real device; the simulator returns the canned preview summary.")
      }

      if let report = model.report {
        Section("Result") {
          Text(report).font(.callout.monospaced())
        }
      }

      if let failure = model.failure {
        Section("Error") {
          Text(failure).font(.callout.monospaced()).foregroundStyle(.red)
        }
      }

      if let summary = model.summary {
        Section("Attribution") {
          WeatherAttributionLink(attribution: summary.attribution)
        }
      }
    }
    .navigationTitle("Weather Test")
  }
}
#endif
