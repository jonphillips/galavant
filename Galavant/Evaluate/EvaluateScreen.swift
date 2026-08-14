import Dependencies
import GalavantAI
import GalavantSchema
import SQLiteData
import SwiftUI

/// The Evaluate section's landing surface: the device-local queue of recommendation
/// handoffs still holding candidates to process (ADR-0037). Promoting evaluation to a
/// top-level destination — rather than a modal buried in a Trip — is what gives the
/// cockpit its own real estate (settles ADR-0037 OQ4). The queue is device-local and
/// unsynced: it reads the same `HandoffSessionStore` the paste door writes to.
struct EvaluateScreen: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = EvaluateQueueModel()
  @State private var openEntry: EvaluateQueueEntry?

  var body: some View {
    Group {
      if model.entries.isEmpty {
        ContentUnavailableView {
          Label("Nothing to evaluate", systemImage: Icon.recommend.systemName)
        } description: {
          Text("Paste a recommendation result into a trip to start a candidate set. Sets with candidates left to process show up here.")
        }
      } else {
        List(model.entries) { entry in
          Button {
            openEntry = entry
          } label: {
            EvaluateQueueRow(entry: entry)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .navigationTitle("Evaluate")
    // The store lives in UserDefaults, not an observed query — reload when the section
    // appears and whenever the app returns to the foreground (a paste in another scene
    // or the share extension may have added a set).
    .task { model.reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.reload() }
    }
    .navigationDestination(item: $openEntry) { entry in
      RecommendationWorkspaceHost(tripID: entry.tripID, sessionID: entry.sessionID)
    }
  }
}

/// One processable set in the queue: a session + its trip, resolved to display facts.
struct EvaluateQueueEntry: Identifiable, Hashable {
  let sessionID: HandoffSession.ID
  let tripID: Trip.ID
  let tripName: String
  let remainingCount: Int
  let createdAt: Date

  var id: HandoffSession.ID { sessionID }
}

private struct EvaluateQueueRow: View {
  let entry: EvaluateQueueEntry

  var body: some View {
    HStack(spacing: 12) {
      Icon.recommend.image
        .font(.title3)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.tripName)
          .font(.headline)
        Text("^[\(entry.remainingCount) candidate](inflect: true) to review · added \(entry.createdAt, format: .dateTime.month().day())")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Icon.disclosure.image
        .font(.footnote)
        .foregroundStyle(.tertiary)
    }
    .contentShape(.rect)
    .padding(.vertical, 4)
  }
}

/// Loads the device-local handoff queue and derives the processable entries. The pure
/// "which sessions still have work" filter mirrors `RecommendationWorkspaceModel`'s
/// candidate predicate so the queue never lists a set the workspace would show as empty.
@MainActor
@Observable
final class EvaluateQueueModel {
  @ObservationIgnored @Dependency(\.handoffSessionStore) private var handoffSessionStore
  @ObservationIgnored @FetchAll(Trip.all) private var trips
  @ObservationIgnored @FetchAll(TripIdea.all) private var allTripIdeas
  private(set) var sessions: [HandoffSession] = []

  func reload() {
    sessions = handoffSessionStore.sessions()
  }

  var entries: [EvaluateQueueEntry] {
    let tripsByID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
    let tripIdeasByID = Dictionary(uniqueKeysWithValues: allTripIdeas.map { ($0.id, $0) })
    return sessions
      .filter {
        $0.taskType == RecommendationHandoffTask.candidatePlaces
          && $0.hasCommittedRecommendationCandidates
      }
      .sorted { $0.createdAt > $1.createdAt }
      .compactMap { session -> EvaluateQueueEntry? in
        guard let trip = tripsByID[session.sourceID] else { return nil }
        let remaining = session.candidateLinks
          .compactMap(\.tripIdeaID)
          .filter { tripIdeaID in
            guard let tripIdea = tripIdeasByID[tripIdeaID] else { return false }
            return tripIdea.status == .considering
              || (tripIdea.status == .scheduled && tripIdea.ideaID == nil)
          }
          .count
        guard remaining > 0 else { return nil }
        return EvaluateQueueEntry(
          sessionID: session.id,
          tripID: trip.id,
          tripName: trip.name,
          remainingCount: remaining,
          createdAt: session.createdAt
        )
      }
  }
}
