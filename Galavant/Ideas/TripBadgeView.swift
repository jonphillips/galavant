import GalavantSchema
import SwiftUI

/// Presentation for an `IdeaTripBadge` (the pure association is schema-side; the
/// glyph/tint/wording live here). A small tinted pill on an Ideas-list cell
/// showing where an idea sits across the in-play trips.
extension IdeaTripBadge {
  var icon: Icon {
    switch self {
    case .scheduled: .calendar
    case .upcoming: .trips
    case .someday: .someday
    case .visited: .checkmark
    }
  }

  var tint: Color {
    switch self {
    case .scheduled: .blue          // an in-play, placed stop reads "committed"
    case .upcoming: .orange
    case .someday, .visited: .secondary
    }
  }

  var text: String {
    switch self {
    case let .scheduled(trip, dayNumber):
      if let dayNumber { "\(trip) · Day \(dayNumber)" } else { "\(trip) · To Be Scheduled" }
    case let .upcoming(trip): trip
    case let .someday(trip): "\(trip) · someday"
    case .visited: "Visited"
    }
  }
}

struct TripBadgeView: View {
  let badge: IdeaTripBadge

  var body: some View {
    HStack(spacing: 4) {
      badge.icon.image
        .imageScale(.small)
      Text(badge.text)
        .lineLimit(1)
    }
    .font(.caption2)
    .foregroundStyle(badge.tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 3)
    .background(
      Capsule().fill(badge.tint.opacity(0.12))
    )
    .overlay(
      Capsule().strokeBorder(badge.tint.opacity(0.35), lineWidth: 0.5)
    )
  }
}
