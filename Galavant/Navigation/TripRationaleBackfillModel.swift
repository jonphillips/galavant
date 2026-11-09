import Dependencies
import GalavantSchema
import LLMHandoffKit
import Observation
import SQLiteData

/// Reconstructs legacy stop rationale from this device's handoff history.
@MainActor
@Observable
final class TripRationaleBackfillModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.handoffSessionStore) private var handoffSessionStore

  func run() async {
    let sessions = handoffSessionStore.sessions().sorted { $0.id.uuidString < $1.id.uuidString }
    for session in sessions {
      await withErrorReporting {
        let candidates = try session.recommendationCandidates()
        let priorityOutOf = candidates.filter { $0.priority != nil }.count
        let candidatesByID = candidates.reduce(into: [TripCandidate.ID: TripCandidate]()) { result, candidate in
          result[candidate.id] = candidate
        }
        for link in session.candidateLinks {
          guard let stopID = link.tripIdeaID, let candidate = candidatesByID[link.candidateID] else { continue }
          try await database.write { db in
            guard let stop = try TripIdea.find(stopID).fetchOne(db),
              let rationale = TripRationaleBackfill.update(
                for: stop, from: candidate, priorityOutOf: candidate.priority == nil ? nil : priorityOutOf)
            else { return }
            try TripIdea.find(stopID).update {
              $0.rationaleVisit = #bind(rationale.visit)
              $0.rationaleWhy = #bind(rationale.why)
              $0.rationaleFit = #bind(rationale.fit)
              $0.rationalePriority = #bind(rationale.priority)
              $0.rationalePriorityOutOf = #bind(rationale.priorityOutOf)
              $0.inlineNote = #bind(rationale.note)
            }.execute(db)
          }
        }
      }
    }
  }
}
