import Dependencies
import Foundation
import Vision

/// Scores a candidate image's header-worthiness from its pixels — the on-device
/// "which photo is best" judge (BACKLOG: Jon's image-pick instinct, resolved to
/// Vision over the text-only language model). Injectable so `PlaceEnricher` stays
/// testable with a fixture, and so the deterministic parser order is the fallback
/// whenever Vision is unavailable/unsure (every score ties → original order holds).
public struct ImageRecommender: Sendable {
  /// A header-worthiness score in 0...1 (higher = better). Utility images (logos,
  /// screenshots, documents) score near zero so they sink below real photos.
  var score: @Sendable (_ data: Data) async -> Double

  public init(score: @escaping @Sendable (_ data: Data) async -> Double) {
    self.score = score
  }

  public func callAsFunction(_ data: Data) async -> Double {
    await score(data)
  }
}

extension ImageRecommender: DependencyKey {
  public static let liveValue = ImageRecommender { data in
    let request = CalculateImageAestheticsScoresRequest()
    guard let observation = try? await request.perform(on: data) else { return 0 }
    // overallScore is roughly -1...1; map to 0...1. Utility images are demoted hard
    // so a logo or screenshot never wins the header over an actual photograph.
    let normalized = (Double(observation.overallScore) + 1) / 2
    return observation.isUtility ? normalized * 0.1 : normalized
  }

  /// No Vision in tests/previews — a flat score keeps the parser's
  /// structured-source-first order (the heuristic fallback).
  public static let testValue = ImageRecommender { _ in 0.5 }
}

extension DependencyValues {
  public var imageRecommender: ImageRecommender {
    get { self[ImageRecommender.self] }
    set { self[ImageRecommender.self] = newValue }
  }
}
