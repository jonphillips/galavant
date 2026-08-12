import Foundation
import SQLiteData

extension TripIdea {
  /// Persist a new intra-day order. Leading Anytime rows use negative ranks to
  /// preserve the explicit “before the first timed event” placement without
  /// changing the behavior of untouched historical rows.
  public static func reorderDayStops(
    _ orderedIDs: [TripIdea.ID],
    leadingAnytimeIDs: Set<TripIdea.ID> = [],
    in db: Database
  ) throws {
    for (index, id) in orderedIDs.enumerated() {
      let rank = leadingAnytimeIDs.contains(id)
        ? Double(index - leadingAnytimeIDs.count)
        : Double(index)
      try TripIdea.find(id).update { $0.dayRank = rank }.execute(db)
    }
  }
}
