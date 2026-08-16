import SwiftUI

/// The required Apple Weather mark and legal-attribution link. Weather-bearing
/// surfaces receive this from `WeatherSummary.attribution` and place it near
/// their displayed forecast.
struct WeatherAttributionLink: View {
  @Environment(\.colorScheme) private var colorScheme

  var attribution: WeatherSummary.Attribution

  var body: some View {
    Link(destination: attribution.legalPageURL) {
      AsyncImage(url: markURL) { image in
        image
          .resizable()
          .scaledToFit()
      } placeholder: {
        Text("Apple Weather", comment: "Fallback label for the required weather-data attribution link.")
      }
    }
    .accessibilityLabel("Apple Weather attribution")
    .accessibilityHint("Opens the legal attribution for weather data.")
  }

  private var markURL: URL {
    colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL
  }
}
