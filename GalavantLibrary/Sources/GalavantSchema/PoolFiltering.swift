import Foundation

/// Pure pool-scoping logic — the heart of the "Virginia case." Filters the
/// idea pool by an optional region (coordinate containment), an optional set
/// of kinds, and visited-state. Pure so it's the densely-tested core.
public func poolFiltered(
  _ ideas: [Idea],
  region: MapRegion?,
  kinds: Set<IdeaKind> = [],
  includeVisited: Bool = true
) -> [Idea] {
  ideas.filter { idea in
    if let region {
      // A region filter only surfaces located ideas inside its bounds.
      guard
        let latitude = idea.latitude,
        let longitude = idea.longitude,
        region.contains(latitude: latitude, longitude: longitude)
      else { return false }
    }
    if !kinds.isEmpty {
      guard let kind = idea.kind, kinds.contains(kind) else { return false }
    }
    if !includeVisited, idea.visited {
      return false
    }
    return true
  }
}
