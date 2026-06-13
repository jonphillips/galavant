import GalavantSchema
import SwiftUI

/// One trip in the list: name, a certainty summary, and the duration.
struct TripRow: View {
  let trip: Trip

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(trip.name.isEmpty ? "Untitled Trip" : trip.name)
        .font(.headline)
      HStack(spacing: 6) {
        Text(certaintySummary)
        Text("·")
        Text("^[\(trip.lengthInDays) day](inflect: true)")
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  /// Human-readable commitment level, derived from the domain `Certainty`.
  private var certaintySummary: String {
    switch trip.certainty {
    case .someday:
      "Someday"
    case let .targeted(year, quarter):
      if let quarter { "\(quarter.label) \(year)" } else { "\(year)" }
    case let .dated(start):
      start.formatted(date: .abbreviated, time: .omitted)
    }
  }
}
