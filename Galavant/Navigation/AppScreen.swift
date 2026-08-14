import SwiftUI

/// Top-level sections of the app. The adaptive shell renders these as tabs on
/// iPhone and a sidebar+detail split on iPad/Mac.
enum AppScreen: Codable, Hashable, Identifiable, CaseIterable {
  case trips
  case ideas
  case browser
  case evaluate
  case settings

  var id: Self { self }

  @ViewBuilder
  var label: some View {
    switch self {
    case .ideas: Icon.ideas.label("Ideas")
    case .trips: Icon.trips.label("Trips")
    case .browser: Icon.browser.label("Browser")
    case .evaluate: Icon.recommend.label("Evaluate")
    case .settings: Icon.settings.label("Settings")
    }
  }

  @ViewBuilder
  var destination: some View {
    switch self {
    case .ideas: IdeasScreen()
    case .trips: TripsScreen()
    case .browser: BrowserScreen()
    case .evaluate: EvaluateScreen()
    case .settings: SettingsScreen()
    }
  }
}
