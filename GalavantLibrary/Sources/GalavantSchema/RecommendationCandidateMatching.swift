import Foundation
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
  }

  public static func merging(
    existing: [TripCandidate],
    incoming: [TripCandidate]
  ) -> Merge {
    var identities = Set(existing.compactMap(RecommendationCandidateIdentity.init(candidate:)))
    var addedCandidates: [TripCandidate] = []

    for candidate in incoming {
      guard let identity = RecommendationCandidateIdentity(candidate: candidate) else {
        addedCandidates.append(candidate)
        continue
      }
      if identities.insert(identity).inserted {
        addedCandidates.append(candidate)
      }
    }

    return Merge(candidates: existing + addedCandidates, addedCandidates: addedCandidates)
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
