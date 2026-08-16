import Foundation

/// Pure selection logic for Journey's optional third stay card. The result is
/// deterministic for a stay and its current candidates, so SwiftUI updates do
/// not reshuffle the image while the user is looking at it.
public enum JourneyImageSelection {
  public static func stableStayStop(
    stayID: TripStay.ID,
    nights: Range<Int>,
    days: [JourneyProjection.DaySummary],
    hasImage: (Idea.ID?) -> Bool
  ) -> JourneyProjection.StopDigest? {
    let candidates = days
      .filter { nights.contains($0.dayNumber) }
      .flatMap(\.stops)
      .filter { hasImage($0.ideaID) }
    guard !candidates.isEmpty else { return nil }

    let seed = stayID.uuidString + candidates.map(\.id.uuidString).joined(separator: "|")
    return candidates[index(for: seed, count: candidates.count)]
  }

  private static func index(for seed: String, count: Int) -> Int {
    // FNV-1a is a small, deterministic hash; unlike Hashable.hashValue it is
    // stable across launches, which keeps a selected stay's card predictable.
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in seed.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Int(hash % UInt64(count))
  }
}
