import Foundation

/// A hand-set Michelin distinction, stored in the same shape as a captured guide result.
public enum MichelinDistinction: Hashable, Sendable {
  case none
  case guide
  case bibGourmand
  case stars(Int)
  case keys(Int)

  public static let sourceName = "Michelin Guide"

  public static func choices(isStay: Bool) -> [MichelinDistinction] {
    if isStay {
      return [.none, .guide, .keys(1), .keys(2), .keys(3)]
    }
    return [.none, .guide, .bibGourmand, .stars(1), .stars(2), .stars(3)]
  }

  public var label: String {
    switch self {
    case .none: "None"
    case .guide: "Guide"
    case .bibGourmand: "Bib Gourmand"
    case let .stars(count): String(repeating: "★", count: count)
    case let .keys(count): String(repeating: "🗝", count: count)
    }
  }

  public var evaluationFields: (kind: EvaluationKind, text: String, display: String, number: Double?, maximum: Double?)? {
    switch self {
    case .none:
      nil
    case .guide:
      (.recommendation, "Recommended", "Recommended", nil, nil)
    case .bibGourmand:
      (.badge, "Bib Gourmand", "Bib Gourmand", nil, nil)
    case let .stars(count) where (1...3).contains(count):
      (.stars, "\(count) star\(count == 1 ? "" : "s")", String(repeating: "★", count: count), Double(count), 3)
    case let .keys(count) where (1...3).contains(count):
      (.stars, "\(count) key\(count == 1 ? "" : "s")", String(repeating: "🗝", count: count), Double(count), 3)
    default:
      nil
    }
  }

  public init?(evaluation: IdeaEvaluation) {
    guard evaluation.confidence == .manual,
          evaluation.canonicalSourceName == Self.sourceName
    else { return nil }

    switch evaluation.kind {
    case .recommendation where evaluation.nativeDisplay == "Recommended":
      self = .guide
    case .badge where evaluation.nativeDisplay == "Bib Gourmand":
      self = .bibGourmand
    case .stars:
      guard let number = evaluation.nativeValueNumber,
            number.rounded() == number,
            (1...3).contains(Int(number))
      else { return nil }
      let count = Int(number)
      if evaluation.nativeDisplay.hasPrefix("🗝") {
        self = .keys(count)
      } else if evaluation.nativeDisplay == String(repeating: "★", count: count) {
        self = .stars(count)
      } else {
        return nil
      }
    default:
      return nil
    }
  }
}
