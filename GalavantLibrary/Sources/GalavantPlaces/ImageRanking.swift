import Foundation

struct ImageRankingCandidate: Equatable, Sendable {
  var index: Int
  var visionScore: Double
  var width: Int
  var height: Int
}

enum ImageRanking {
  static let minimumLongestEdge = 400

  // Keep Vision as the primary signal; area only nudges close scores toward
  // candidates that have enough pixels to make a useful stored photo.
  private static let visionWeight = 0.85
  private static let areaWeight = 1 - visionWeight
  private static let referenceArea = Double(1600 * 1600)

  /// Orders usable images by Vision score with a modest bias toward larger source
  /// images. Parser order is the deterministic tiebreaker.
  static func ordered(_ candidates: [ImageRankingCandidate]) -> [ImageRankingCandidate] {
    candidates
      .filter { max($0.width, $0.height) >= minimumLongestEdge }
      .sorted { lhs, rhs in
        let lhsScore = combinedScore(lhs)
        let rhsScore = combinedScore(rhs)
        return lhsScore == rhsScore ? lhs.index < rhs.index : lhsScore > rhsScore
      }
  }

  private static func combinedScore(_ candidate: ImageRankingCandidate) -> Double {
    let visionScore = candidate.visionScore.isFinite
      ? min(max(candidate.visionScore, 0), 1)
      : 0
    let area = Double(max(candidate.width, 1)) * Double(max(candidate.height, 1))
    let areaScore = min(log2(area) / log2(referenceArea), 1)
    return visionScore * visionWeight + areaScore * areaWeight
  }
}
