import Foundation

/// Pure pool-scoping logic — the heart of the "Virginia case." Filters the
/// idea pool by a set of regions (coordinate containment — an idea matches if it
/// falls inside *any* of them, so a multi-region trip unions its areas), an
/// optional set of kinds, and visited-state. An empty `regions` means no
/// geographic constraint. Pure so it's the densely-tested core.
///
/// `pinnedIDs` bypass the **region** constraint only: ideas already pulled onto the
/// active trip must always show in its capsule (the trip's working surface), even if
/// they fall outside the trip's saved regions — they still respect kind/tag/visited.
public func poolFiltered(
  _ ideas: [Idea],
  regions: [MapRegion] = [],
  kinds: Set<IdeaKind> = [],
  includeVisited: Bool = true,
  tagIDs selectedTagIDs: Set<Tag.ID> = [],
  ideaTagIDs: [Idea.ID: Set<Tag.ID>] = [:],
  pinnedIDs: Set<Idea.ID> = []
) -> [Idea] {
  ideas.filter { idea in
    if !regions.isEmpty, !pinnedIDs.contains(idea.id) {
      // A region filter only surfaces located ideas inside at least one region.
      guard
        let latitude = idea.latitude,
        let longitude = idea.longitude,
        regions.contains(where: { $0.contains(latitude: latitude, longitude: longitude) })
      else { return false }
    }
    if !kinds.isEmpty {
      guard let kind = idea.kind, kinds.contains(kind) else { return false }
    }
    if !selectedTagIDs.isEmpty {
      // Selecting more tags narrows: the idea must carry all selected tags.
      guard selectedTagIDs.isSubset(of: ideaTagIDs[idea.id] ?? []) else { return false }
    }
    if !includeVisited, idea.visited {
      return false
    }
    return true
  }
}
