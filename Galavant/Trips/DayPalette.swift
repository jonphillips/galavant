import SwiftUI

/// Map pin and route colors distinguish itinerary days. Consecutive days contrast
/// most; days past the cycle length wrap.
enum DayPalette {
  /// Ten hues ordered to keep adjacent days visually distinct.
  static let colors: [Color] = [
    .red, .blue, .orange, .purple, .green,
    .cyan, .brown, .pink, .indigo, .yellow,
  ]

  /// The colour for a 1-based day number. Out-of-range/zero days clamp to the
  /// first colour rather than crashing.
  static func color(forDay day: Int) -> Color {
    guard day >= 1 else { return colors[0] }
    return colors[(day - 1) % colors.count]
  }
}
