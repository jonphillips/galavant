import SwiftUI

/// The colour each itinerary day wears on the trip canvas — pins, polylines, and
/// day chips all draw from this so a day reads as one colour across the map and
/// the timeline. A fixed, visually-distinct cycle; days past the cycle length
/// wrap (a trip rarely runs long enough to repeat a neighbour).
enum DayPalette {
  /// Distinct hues, deliberately ordered so adjacent days don't collide.
  static let colors: [Color] = [
    .red, .blue, .green, .orange, .purple,
    .pink, .teal, .indigo, .brown, .mint,
  ]

  /// The colour for a 1-based day number. Out-of-range/zero days clamp to the
  /// first colour rather than crashing.
  static func color(forDay day: Int) -> Color {
    guard day >= 1 else { return colors[0] }
    return colors[(day - 1) % colors.count]
  }
}
