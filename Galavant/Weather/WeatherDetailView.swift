import SwiftUI

/// A compact, presentation-only read of the weather value already loaded by a
/// weather-bearing surface.
struct WeatherDetailView: View {
  let summary: WeatherSummary

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Weather")
          .font(.title2.weight(.bold))

        if let current = summary.current {
          detailSection(title: "Current") {
            weatherRow("Condition", current.condition.capitalized)
            weatherRow("Temperature", temperature(current.temperature))
          }
        }

        if let daily = summary.daily {
          detailSection(title: "Forecast") {
            weatherRow("Condition", daily.condition.capitalized)
            weatherRow("High", temperature(daily.highTemperature))
            weatherRow("Low", temperature(daily.lowTemperature))
            weatherRow("Precipitation", precipitation(daily.precipitationChance))
          }
        }

        if let hourly = summary.hourlyInterval.first {
          detailSection(title: "Hourly") {
            weatherRow("Condition", hourly.condition.capitalized)
            weatherRow("Temperature", temperature(hourly.temperature))
            weatherRow("Precipitation", precipitation(hourly.precipitationChance))
          }
        }

        if let alert = summary.alert {
          detailSection(title: "Alert") {
            Text(alert.summary)
            if !alert.severity.isEmpty {
              Text(alert.severity.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Link("View weather alert", destination: alert.detailsURL)
          }
        }

        WeatherAttributionLink(attribution: summary.attribution)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding()
    }
  }

  @ViewBuilder
  private func detailSection<Content: View>(
    title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      content()
    }
  }

  private func weatherRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 16)
      Text(value)
        .fontWeight(.medium)
        .multilineTextAlignment(.trailing)
    }
  }

  private func temperature(_ measurement: Measurement<UnitTemperature>) -> String {
    measurement.formatted(
      .measurement(
        width: .narrow,
        usage: .weather,
        numberFormatStyle: .number.precision(.fractionLength(0))))
  }

  private func precipitation(_ chance: Double) -> String {
    chance.formatted(.percent.precision(.fractionLength(0)))
  }
}
