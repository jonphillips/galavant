import SwiftUI

/// Placeholder until M3. Trips will pull ideas from the pool into dated and
/// "someday" trips (ADR-0004, docs/trip-time-model.md).
struct TripsScreen: View {
  var body: some View {
    ContentUnavailableView {
      Label("Trips", systemImage: "suitcase")
    } description: {
      Text("Next milestone: pull ideas from the pool into dated and someday trips, then schedule them day by day.")
    }
    .navigationTitle("Trips")
  }
}
