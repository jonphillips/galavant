import Foundation

/// Derives the browser's first destination for a recommendation candidate. The
/// handoff supplies a search hint, never a URL; a confirmed Maps place is the
/// only source that can supply an official website (ADR-0037 D5).
public enum BrowserTargetDerivation {
  public enum Resolution: Equatable, Hashable, Sendable {
    case unresolved
    case resolved(officialURL: URL?)
  }

  public enum Target: Equatable, Hashable, Sendable {
    case search(query: String)
    case website(URL)
    case unavailable
  }

  public static func target(for candidate: TripCandidate, resolution: Resolution) -> Target {
    switch resolution {
    case .unresolved:
      guard let searchHint = candidate.searchHint else { return .unavailable }
      return .search(query: searchHint)
    case let .resolved(officialURL):
      return officialURL.map(Target.website) ?? .unavailable
    }
  }
}

/// Determines whether resolving a candidate created a second trip row for one
/// pool idea. The caller owns the write and asks the human whether to merge or
/// retain both rows (ADR-0037 OQ5).
public struct ResolveReconcile: Equatable, Sendable {
  public enum Choice: Equatable, Sendable {
    case merge
    case keepBoth
  }

  public enum Action: Equatable, Sendable {
    case merge(existingID: TripIdea.ID, duplicateID: TripIdea.ID, inlineNote: String?)
    case keepBoth
  }

  public struct Collision: Equatable, Sendable {
    public let existingID: TripIdea.ID
    public let duplicateID: TripIdea.ID
    public let existingStatus: TripIdeaStatus
    public let mergedInlineNote: String?

    public func action(for choice: Choice) -> Action {
      switch choice {
      case .merge:
        .merge(existingID: existingID, duplicateID: duplicateID, inlineNote: mergedInlineNote)
      case .keepBoth:
        .keepBoth
      }
    }
  }

  public let collision: Collision?

  /// `candidateID` identifies the row just resolved. Scheduled and shortlisted
  /// rows win over a still-considering peer so a merge preserves the more mature
  /// trip placement; ranks and UUIDs make the choice stable when several peers
  /// already share the same place.
  public init(
    tripIdeas: [TripIdea],
    resolvedIdeaID: Idea.ID,
    candidateID: TripIdea.ID
  ) {
    guard let candidate = tripIdeas.first(where: { $0.id == candidateID && $0.ideaID == resolvedIdeaID }) else {
      collision = nil
      return
    }

    let existing = tripIdeas
      .filter {
        $0.id != candidate.id
          && $0.tripID == candidate.tripID
          && $0.ideaID == resolvedIdeaID
          && Self.isLiveTripPlacement($0.status)
      }
      .sorted(by: Self.preferredExistingOrder)
      .first

    collision = existing.map {
      Collision(
        existingID: $0.id,
        duplicateID: candidate.id,
        existingStatus: $0.status,
        mergedInlineNote: Self.mergedNote(existing: $0.inlineNote, duplicate: candidate.inlineNote)
      )
    }
  }

  private static func isLiveTripPlacement(_ status: TripIdeaStatus) -> Bool {
    switch status {
    case .considering, .shortlisted, .scheduled: true
    case .done, .skipped: false
    }
  }

  private static func preferredExistingOrder(_ lhs: TripIdea, _ rhs: TripIdea) -> Bool {
    (placementPriority(lhs.status), lhs.shortlistRank, lhs.id.uuidString)
      < (placementPriority(rhs.status), rhs.shortlistRank, rhs.id.uuidString)
  }

  private static func placementPriority(_ status: TripIdeaStatus) -> Int {
    switch status {
    case .scheduled: 0
    case .shortlisted: 1
    case .considering: 2
    case .done, .skipped: 3
    }
  }

  /// The same preservation rule as `IdeaInterest`: retain every distinct,
  /// non-empty note in a deterministic order, separated for readability.
  private static func mergedNote(existing: String?, duplicate: String?) -> String? {
    let notes = [existing, duplicate]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .reduce(into: [String]()) { result, note in
        if !result.contains(note) { result.append(note) }
      }
    return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
  }
}
