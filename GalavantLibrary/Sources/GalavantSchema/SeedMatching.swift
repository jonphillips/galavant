import Foundation

/// The normalized names a seed row may use to identify a saved idea.
public enum SeedMatchKeys {
  public static func make(name: String?, searchHint: String?) -> [String] {
    let values = [name, searchHint?.components(separatedBy: ",").first]
    var seen = Set<String>()
    return values.compactMap { value in
      guard let value else { return nil }
      let withoutCompany = value.replacingOccurrences(
        of: #"\s+(?:ApS|A/S|I/S|GmbH|Ltd)\.?$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      guard let key = RecommendationCandidateIdentity.normalized(withoutCompany), seen.insert(key).inserted
      else { return nil }
      return key
    }
  }
}

public enum SeedPoolMatch: Equatable, Sendable {
  case idea(Idea)
  case ambiguous([Idea])
  case none

  public static func match(keys: [String], locality: String?, ideas: [Idea]) -> SeedPoolMatch {
    let localityKey = RecommendationCandidateIdentity.normalized(locality)
    let matches = ideas.filter { idea in
      guard let name = RecommendationCandidateIdentity.normalized(idea.name), keys.contains(name) else {
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
