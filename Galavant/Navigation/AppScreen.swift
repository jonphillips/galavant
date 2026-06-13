import SwiftUI

/// Top-level sections of the app. The adaptive shell renders these as tabs on
/// iPhone and a sidebar+detail split on iPad/Mac.
enum AppScreen: Codable, Hashable, Identifiable, CaseIterable {
  case ideas
  case trips

  var id: Self { self }

  @ViewBuilder
  var label: some View {
    switch self {
    case .ideas: Label("Ideas", systemImage: "lightbulb")
    case .trips: Label("Trips", systemImage: "suitcase")
    }
  }

  @ViewBuilder
  var destination: some View {
    switch self {
    case .ideas: IdeasScreen()
    case .trips: TripsScreen()
    }
  }
}
