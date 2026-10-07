import Foundation

/// Name keys shared by saved-idea matching and Maps preselection.
public struct SeedMatchKeys: Equatable, Sendable {
  public var compact: [String]
  public var words: [String]

  public static func make(name: String?, searchHint: String?) -> SeedMatchKeys {
    let values = [name, searchHint?.components(separatedBy: ",").first]
    var seenCompact = Set<String>()
    var seenWords = Set<String>()
    var compact: [String] = []
    var words: [String] = []
    for value in values.compactMap({ $0 }) {
      let withoutCompany = value.replacingOccurrences(
        of: #"\s+(?:ApS|A/S|I/S|GmbH|Ltd)\.?$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      let folded = withoutCompany.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      if let key = RecommendationCandidateIdentity.normalized(folded), seenCompact.insert(key).inserted {
        compact.append(key)
      }
      if !folded.isEmpty, seenWords.insert(folded).inserted { words.append(folded) }
    }
    return SeedMatchKeys(compact: compact, words: words)
  }

  public init(compact: [String], words: [String]) {
    self.compact = compact
    self.words = words
  }
}

public enum SeedPoolMatch: Equatable, Sendable {
  case idea(Idea)
  case ambiguous([Idea])
  case none

  public static func match(keys: SeedMatchKeys, locality: String?, ideas: [Idea]) -> SeedPoolMatch {
    let localityKey = RecommendationCandidateIdentity.normalized(locality)
    let matches = ideas.filter { idea in
      guard let name = RecommendationCandidateIdentity.normalized(idea.name), keys.compact.contains(name) else {
        return false
      }
      guard let localityKey, let address = RecommendationCandidateIdentity.normalized(idea.address) else {
        return true
      }
      return address.contains(localityKey)
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    return switch matches.count {
    case 0: .none
    case 1: .idea(matches[0])
    default: .ambiguous(matches)
    }
  }

  public static func match(mapItemIdentifier: String, ideas: [Idea]) -> Idea? {
    ideas.first { $0.mapItemIdentifier == mapItemIdentifier }
  }
}
