import Foundation

/// One read-only projection for tag pickers, counts, and idea-row labels.
public struct TagIndex: Sendable {
  public let tags: [Tag]
  public let useCountByTagID: [Tag.ID: Int]
  public let namesByIdeaID: [Idea.ID: [String]]
  public let survivorIDByTagID: [Tag.ID: Tag.ID]

  public init(tags: [Tag], ideaTags: [IdeaTag]) {
    let converged = tags.convergingByKey(Tag.logicalKey)
    let tagsByKey = Dictionary(grouping: tags, by: Tag.logicalKey)
    let survivorByID = Dictionary(uniqueKeysWithValues: tagsByKey.values.flatMap { group in
      let survivor = group.convergingByKey { _ in true }.survivors[0]
      return group.map { ($0.id, survivor.id) }
    })
    self.tags = converged.survivors.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    self.survivorIDByTagID = survivorByID
    let nameBySurvivorID = Dictionary(uniqueKeysWithValues: converged.survivors.map { ($0.id, $0.name) })

    let validJoins = ideaTags.compactMap { join -> (Idea.ID, Tag.ID)? in
      guard let survivorID = survivorByID[join.tagID] else { return nil }
      return (join.ideaID, survivorID)
    }
    let ideasByTag = Dictionary(grouping: validJoins, by: { $0.1 })
    self.useCountByTagID = Dictionary(uniqueKeysWithValues: ideasByTag.map { tagID, joins in
      (tagID, Set(joins.map(\.0)).count)
    })
    let namesByIdea = Dictionary(grouping: validJoins, by: \.0)
    self.namesByIdeaID = namesByIdea.mapValues { joins in
      Set(joins.compactMap { join in
        nameBySurvivorID[join.1]
      }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
  }

  public var liveTagIDs: Set<Tag.ID> { Set(tags.map(\.id)) }

  /// Keep only existing selected tags, mapping pre-convergence IDs to their survivor.
  public func effectiveSelection(_ selected: Set<Tag.ID>) -> Set<Tag.ID> {
    Set(selected.compactMap { survivorIDByTagID[$0] })
  }

  public func names(for ideaID: Idea.ID) -> [String] { namesByIdeaID[ideaID] ?? [] }

  public func useCount(for tagID: Tag.ID) -> Int { useCountByTagID[tagID] ?? 0 }
}
