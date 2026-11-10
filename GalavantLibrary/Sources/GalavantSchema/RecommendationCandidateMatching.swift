import Foundation
import GalavantAI
import SQLiteData

/// The stable identity of an LLM-proposed place within one recommendation set.
/// Candidate UUIDs are transport-local, so re-pastes compare the human-facing
/// name and locality instead.
public struct RecommendationCandidateIdentity: Hashable, Sendable {
  public let name: String
  public let locality: String?

  public init?(candidate: TripCandidate) {
    guard let name = Self.normalized(candidate.name) else { return nil }
    self.name = name
    self.locality = Self.normalized(candidate.locality)
  }

  static func normalized(_ text: String?) -> String? {
    guard let text else { return nil }
    let folded = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil
    )
    let alphanumeric = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    return alphanumeric.isEmpty ? nil : alphanumeric
  }
}

/// Pure set reconciliation for a handoff's device-local candidates. Keeping this
/// independent of storage means a re-paste cannot discard links to rows already
/// committed from the first paste.
public enum RecommendationCandidateSet {
  public struct Merge: Equatable, Sendable {
    public let candidates: [TripCandidate]
    public let addedCandidates: [TripCandidate]
    public let updatedCandidates: [TripCandidate]
    public let unrankedCandidates: [TripCandidate]
  }

  public static func merging(
    existing: [TripCandidate],
    incoming: [TripCandidate]
  ) -> Merge {
    var seenIncoming = Set<RecommendationCandidateIdentity>()
    let uniqueIncoming = incoming.filter { candidate in
      guard let identity = RecommendationCandidateIdentity(candidate: candidate) else { return true }
      return seenIncoming.insert(identity).inserted
    }
    let hasRanking = uniqueIncoming.contains { $0.priority != nil }
    var candidates = existing
    var addedCandidates: [TripCandidate] = []
    var updatedCandidates: [TripCandidate] = []
    let stampedIncoming = Self.stamp(uniqueIncoming)

    for candidate in stampedIncoming {
      guard let identity = RecommendationCandidateIdentity(candidate: candidate) else {
        addedCandidates.append(candidate)
        continue
      }
      if let existingIndex = candidates.firstIndex(where: {
        RecommendationCandidateIdentity(candidate: $0) == identity
      }) {
        var updated = candidate
        updated = TripCandidate(
          id: candidates[existingIndex].id, name: updated.name, locality: updated.locality,
          searchHint: updated.searchHint, why: updated.why, fit: updated.fit, kind: updated.kind,
          visit: updated.visit,
          priority: hasRanking ? updated.priority : candidates[existingIndex].priority,
          priorityOutOf: hasRanking ? updated.priorityOutOf : candidates[existingIndex].priorityOutOf,
          list: hasRanking ? updated.list : candidates[existingIndex].list,
          dayRef: updated.dayRef, placementAfter: updated.placementAfter, bookAhead: updated.bookAhead
        )
        candidates[existingIndex] = updated
        updatedCandidates.append(updated)
      } else {
        addedCandidates.append(candidate)
      }
    }

    let incomingIdentities = Set(stampedIncoming.compactMap(RecommendationCandidateIdentity.init(candidate:)))
    var unrankedCandidates: [TripCandidate] = []
    if hasRanking, !updatedCandidates.isEmpty {
      for index in candidates.indices where candidates[index].priority != nil {
        guard let identity = RecommendationCandidateIdentity(candidate: candidates[index]),
          !incomingIdentities.contains(identity)
        else { continue }
        var candidate = candidates[index]
        candidate.priority = nil
        candidate.priorityOutOf = nil
        candidate.list = nil
        candidates[index] = candidate
        unrankedCandidates.append(candidate)
      }
    }

    candidates.append(contentsOf: addedCandidates)
    return Merge(
      candidates: candidates, addedCandidates: addedCandidates,
      updatedCandidates: updatedCandidates, unrankedCandidates: unrankedCandidates
    )
  }

  private static func stamp(_ candidates: [TripCandidate]) -> [TripCandidate] {
    let rankedCount = candidates.filter { $0.priority != nil }.count
    let listName = mostCommonListName(in: candidates)
    return candidates.map { candidate -> TripCandidate in
      var candidate = candidate
      candidate.priorityOutOf = candidate.priority == nil ? nil : rankedCount
      candidate.list = candidate.priority == nil ? nil : listName
      return candidate
    }
  }

  static func mostCommonListName(in candidates: [TripCandidate]) -> String? {
    let names = candidates.compactMap { candidate -> String? in
      guard candidate.priority != nil else { return nil }
      guard let name = candidate.list?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        return nil
      }
      return name
    }
    guard let first = names.first else { return nil }
    let counts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    return names.first(where: { counts[$0] == counts.values.max() }) ?? first
  }

  public static func priorityOutOf(for candidateID: TripCandidate.ID, in candidates: [TripCandidate]) -> Int? {
    guard let candidate = candidates.first(where: { $0.id == candidateID }), candidate.priority != nil else { return nil }
    return candidate.priorityOutOf ?? candidates.filter { $0.priority != nil }.count
  }

  public static func applyReevaluation(
    _ merge: Merge, links: [HandoffCandidateLink], in db: Database
  ) throws {
    let linkByCandidate = Dictionary(uniqueKeysWithValues: links.map { ($0.candidateID, $0.tripIdeaID) })
    let updatedByID = Dictionary(
      merge.updatedCandidates.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let unrankedIDs = Set(merge.unrankedCandidates.map(\.id))
    for (candidateID, candidate) in updatedByID {
      guard let stopID = linkByCandidate[candidateID] ?? nil,
        let stop = try TripIdea.find(stopID).fetchOne(db), isReevaluationLive(stop.status)
      else { continue }
      try TripIdea.find(stopID).update {
        $0.rationaleVisit = #bind(candidate.visit)
        $0.rationaleWhy = #bind(candidate.why)
        $0.rationaleFit = #bind(candidate.fit)
        $0.rationalePriority = #bind(candidate.priority)
        $0.rationalePriorityOutOf = #bind(candidate.priorityOutOf)
        $0.rationalePriorityList = #bind(candidate.list)
      }.execute(db)
    }
    for candidateID in unrankedIDs {
      guard let stopID = linkByCandidate[candidateID] ?? nil,
        let stop = try TripIdea.find(stopID).fetchOne(db), isReevaluationLive(stop.status)
      else { continue }
      try TripIdea.find(stopID).update {
        $0.rationalePriority = #bind(nil as Int?)
        $0.rationalePriorityOutOf = #bind(nil as Int?)
        $0.rationalePriorityList = #bind(nil as String?)
      }.execute(db)
    }
  }

  /// Finds the deterministic live trip row that a reviewed candidate should link
  /// to. Terminal rows are historical, not current trip membership, so they do
  /// not suppress a new candidate.
  public static func liveTripIdea(
    matching candidate: TripCandidate,
    in tripIdeas: [TripIdea],
    ideasByID: [Idea.ID: Idea]
  ) -> TripIdea? {
    guard let title = RecommendationCandidateIdentity.normalized(candidate.name) else { return nil }
    return tripIdeas
      .filter { tripIdea in
        guard isLive(tripIdea.status) else { return false }
        guard let idea = tripIdea.ideaID.flatMap({ ideasByID[$0] }) else {
          return RecommendationCandidateIdentity.normalized(tripIdea.inlineTitle) == title
        }
        guard RecommendationCandidateIdentity.normalized(tripIdea.inlineTitle ?? idea.name) == title else {
          return false
        }
        guard
          let locality = RecommendationCandidateIdentity.normalized(candidate.locality),
          let address = RecommendationCandidateIdentity.normalized(idea.address)
        else { return true }
        return address.contains(locality)
      }
      .min { $0.id.uuidString < $1.id.uuidString }
  }

  private static func isLive(_ status: TripIdeaStatus) -> Bool {
    switch status {
    case .considering, .shortlisted, .scheduled, .declined: true
    case .done, .skipped: false
    }
  }

  private static func isReevaluationLive(_ status: TripIdeaStatus) -> Bool {
    switch status {
    case .considering, .shortlisted, .scheduled: true
    case .declined, .done, .skipped: false
    }
  }
}

extension TripIdea {
  /// The only rows needed to match a candidate against one trip. The pure matcher
  /// below receives this small context, so paste feedback and commit use the same
  /// rows without reading the whole shared idea pool.
  public static func recommendationMatchingContext(
    for tripID: Trip.ID,
    in db: Database
  ) throws -> (tripIdeas: [TripIdea], ideasByID: [Idea.ID: Idea]) {
    let tripIdeas = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let ideaIDs = tripIdeas.compactMap(\.ideaID)
    let ideas = ideaIDs.isEmpty
      ? []
      : try Idea.where { $0.id.in(ideaIDs) }.fetchAll(db)
    return (tripIdeas, Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }))
  }
}
