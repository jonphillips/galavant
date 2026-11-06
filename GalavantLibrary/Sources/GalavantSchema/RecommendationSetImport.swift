import Foundation
import GalavantAI
import SQLiteData

public enum RecommendationSetImport {
  public struct Result: Sendable {
    public let session: HandoffSession
    public let remainingCount: Int
  }

  public static func session(
    token: UUID?, existing: HandoffSession?, tripID: Trip.ID, now: Date, newID: UUID
  ) -> HandoffSession {
    if let existing, existing.id == token, existing.sourceID == tripID { return existing }
    return HandoffSession(
      id: existing == nil ? (token ?? newID) : newID, sourceType: "trip", sourceID: tripID,
      taskType: RecommendationHandoffTask.candidatePlaces, createdAt: now, exportedPrompt: ""
    )
  }

  public static func commit(
    candidate: TripCandidate, into tripID: Trip.ID, session: inout HandoffSession,
    now: Date, in db: Database
  ) throws {
    var candidate = candidate
    if candidate.name == nil { candidate.name = candidate.suggestedTitle }
    let committed = try TripIdea.commit(candidate: candidate, into: tripID, in: db)
    try session.replaceRecommendationCandidate(candidate)
    session.link(candidateID: candidate.id, to: committed.id)
    session.importedAt = now
    session.status = .imported
  }

  public static func apply(
    candidates: [TripCandidate], note: String?, into tripID: Trip.ID,
    session suppliedSession: HandoffSession, now: Date, in db: Database
  ) throws -> Result {
    var session = suppliedSession
    let normalized = candidates.map { candidate in
      var candidate = candidate
      if candidate.name == nil { candidate.name = candidate.suggestedTitle }
      return candidate
    }
    try session.storeRecommendationCandidates(normalized)
    let linked = Set(session.candidateLinks.filter { $0.tripIdeaID != nil }.map(\.candidateID))
    for candidate in try session.recommendationCandidates() where !linked.contains(candidate.id) {
      guard !candidate.suggestedTitle.isEmpty else { continue }
      try commit(candidate: candidate, into: tripID, session: &session, now: now, in: db)
    }
    if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let documents = try TripDocument.where { $0.tripID.eq(tripID) }.fetchAll(db)
      if !documents.contains(where: { $0.origin == .pasted && $0.body == note }) {
        try TripDocument.add(tripID: tripID, title: "Chat notes — \(now.formatted(date: .abbreviated, time: .omitted))", body: note, origin: .pasted, now: now, in: db)
      }
    }
    let ids = Set(session.candidateLinks.compactMap(\.tripIdeaID))
    let tripIdeas = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let remaining = tripIdeas.filter {
      ids.contains($0.id) && ($0.status == .considering || ($0.status == .scheduled && $0.ideaID == nil))
    }.count
    return Result(session: session, remainingCount: remaining)
  }
}
