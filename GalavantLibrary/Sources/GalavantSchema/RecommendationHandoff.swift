import Foundation
import GalavantAI
import SQLiteData

/// Galavant-owned source encoding for recommendation handoffs. The local handoff
/// spine retains only the resulting opaque `sourceType` and `scopeKey` strings.
public enum RecommendationHandoffScope: Equatable, Sendable {
  case day(Int)
  case stay(UUID)
  case transfer(UUID)
  case trip

  public var sourceType: String {
    switch self {
    case .day: "day"
    case .stay: "stay"
    case .transfer: "transfer"
    case .trip: "trip"
    }
  }

  public var scopeKey: String? {
    switch self {
    case let .day(day): String(day)
    case let .stay(id), let .transfer(id): id.uuidString
    case .trip: nil
    }
  }

  public init(sourceType: String, scopeKey: String?) throws {
    switch (sourceType, scopeKey) {
    case let ("day", .some(value)) where Int(value) != nil:
      self = .day(Int(value)!)
    case let ("stay", .some(value)) where UUID(uuidString: value) != nil:
      self = .stay(UUID(uuidString: value)!)
    case let ("transfer", .some(value)) where UUID(uuidString: value) != nil:
      self = .transfer(UUID(uuidString: value)!)
    case ("trip", nil):
      self = .trip
    default:
      throw RecommendationHandoffScopeError.invalidEncoding(sourceType: sourceType, scopeKey: scopeKey)
    }
  }
}

public enum RecommendationHandoffScopeError: Error, Equatable, Sendable {
  case invalidEncoding(sourceType: String, scopeKey: String?)
}

public enum RecommendationHandoffTask {
  public static let candidatePlaces = "candidatePlaces"
}

public enum RecommendationHandoffContract {
  public static let marker = HandoffContractMarker(prefix: "GV-CONTRACT", version: "v1")

  /// The one copyable contract for the user's ChatGPT or Claude project instructions.
  public static let projectInstructions = """
    You are helping plan a Galavant trip. When asked for candidate places, return only the handoff token from the brief, the contract marker below, and one JSON array. Do not wrap the JSON in Markdown.

    GV-CONTRACT: v1

    Candidate JSON fields are optional: name, locality, search_hint, why, fit, kind, visit, priority, day_ref, placement_after. Use name for the place name, locality for its town or neighborhood, search_hint for an Apple Maps-style query, and why/fit for the trip-specific rationale. priority is an integer when you can rank it. day_ref and placement_after are advisory only.

    Return shape:
    GV-HANDOFF: <token from the brief>
    GV-CONTRACT: v1
    [{"name":"…","locality":"…","search_hint":"…","why":"…","fit":"…","kind":"…","visit":"…","priority":0,"day_ref":"…","placement_after":"…"}]
    """

  public static func brief(
    session: HandoffSession,
    tripName: String,
    tripNotes: String,
    plan: TripPlan
  ) -> String {
    let trimmedNotes = tripNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = [
      session.header,
      "Trip: \(tripName)",
    ]
    if !trimmedNotes.isEmpty { lines.append("Trip notes: \(trimmedNotes)") }
    let stops = stopSummary(plan: plan)
    if !stops.isEmpty {
      lines.append("Stops so far:")
      lines.append(contentsOf: stops)
    }
    lines.append("Ask: Recommend candidate places that fit this trip. Give options with a useful locality, search hint, and concise rationale.")
    return lines.joined(separator: "\n")
  }

  /// Compact context for an external recommendation model: only committed stops
  /// and stays, in the same order the itinerary presents them. Shortlist and
  /// considering entries are deliberately absent because they are not yet part
  /// of the trip's current plan.
  public static func stopSummary(plan: TripPlan) -> [String] {
    var lines: [String] = []

    for day in plan.itinerary where !day.stops.isEmpty {
      lines.append("Day \(day.number):")
      lines.append(contentsOf: day.stops.map { "- \(description(for: $0.content))" })
    }

    if !plan.toBeScheduled.isEmpty {
      lines.append("To be scheduled:")
      lines.append(contentsOf: plan.toBeScheduled.map { "- \(description(for: $0.content))" })
    }

    lines.append(contentsOf: plan.stays.map { "Staying: \(description(for: $0.content))" })
    return lines
  }

  private static func description(for content: StopContent) -> String {
    guard let locality = locality(for: content) else { return content.title }
    return "\(content.title) (\(locality))"
  }

  private static func locality(for content: StopContent) -> String? {
    guard case let .idea(idea) = content else { return nil }
    let locality = idea.regionName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return locality?.isEmpty == false ? locality : nil
  }
}

/// One unresolved place proposed by an external LLM. It is a value for the review
/// surface, not a database record: only a human tap creates a durable `TripIdea`.
public struct TripCandidate: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String?
  public var locality: String?
  public var searchHint: String?
  public var why: String?
  public var fit: String?
  public var kind: String?
  public var visit: String?
  public var priority: Int?
  public var dayRef: String?
  public var placementAfter: String?

  public init(
    id: UUID = UUID(),
    name: String? = nil,
    locality: String? = nil,
    searchHint: String? = nil,
    why: String? = nil,
    fit: String? = nil,
    kind: String? = nil,
    visit: String? = nil,
    priority: Int? = nil,
    dayRef: String? = nil,
    placementAfter: String? = nil
  ) {
    self.id = id
    self.name = name?.nonEmpty
    self.locality = locality?.nonEmpty
    self.searchHint = searchHint?.nonEmpty
    self.why = why?.nonEmpty
    self.fit = fit?.nonEmpty
    self.kind = kind?.nonEmpty
    self.visit = visit?.nonEmpty
    self.priority = priority
    self.dayRef = dayRef?.nonEmpty
    self.placementAfter = placementAfter?.nonEmpty
  }

  public var rationale: String? {
    [why, fit].compactMap { $0?.nonEmpty }.joined(separator: "\n\n").nonEmpty
  }

  public var suggestedTitle: String {
    name ?? searchHint ?? locality ?? ""
  }

  enum CodingKeys: String, CodingKey {
    case id, name, locality, searchHint = "search_hint", why, fit, kind, visit, priority
    case dayRef = "day_ref"
    case placementAfter = "placement_after"
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      name: try values.decodeIfPresent(String.self, forKey: .name),
      locality: try values.decodeIfPresent(String.self, forKey: .locality),
      searchHint: try values.decodeIfPresent(String.self, forKey: .searchHint),
      why: try values.decodeIfPresent(String.self, forKey: .why),
      fit: try values.decodeIfPresent(String.self, forKey: .fit),
      kind: try values.decodeIfPresent(String.self, forKey: .kind),
      visit: try values.decodeIfPresent(String.self, forKey: .visit),
      priority: try values.decodeIfPresent(Int.self, forKey: .priority),
      dayRef: try values.decodeIfPresent(String.self, forKey: .dayRef),
      placementAfter: try values.decodeIfPresent(String.self, forKey: .placementAfter)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encodeIfPresent(name, forKey: .name)
    try values.encodeIfPresent(locality, forKey: .locality)
    try values.encodeIfPresent(searchHint, forKey: .searchHint)
    try values.encodeIfPresent(why, forKey: .why)
    try values.encodeIfPresent(fit, forKey: .fit)
    try values.encodeIfPresent(kind, forKey: .kind)
    try values.encodeIfPresent(visit, forKey: .visit)
    try values.encodeIfPresent(priority, forKey: .priority)
    try values.encodeIfPresent(dayRef, forKey: .dayRef)
    try values.encodeIfPresent(placementAfter, forKey: .placementAfter)
  }

  /// Lossless-or-loud boundary: only a complete JSON array enters the review flow.
  /// Prose around the array and curly quotes are transport noise; malformed JSON is
  /// a typed error, never an empty candidate set.
  public static func decodeReturn(_ text: String) throws -> [TripCandidate] {
    guard let array = jsonArraySlice(in: text) else { throw TripCandidateDecodeError.missingJSONArray }
    let normalized = array
      .replacingOccurrences(of: "“", with: "\"")
      .replacingOccurrences(of: "”", with: "\"")
      .replacingOccurrences(of: "‘", with: "'")
      .replacingOccurrences(of: "’", with: "'")
    guard let candidates = try? JSONDecoder().decode([TripCandidate].self, from: Data(normalized.utf8))
    else { throw TripCandidateDecodeError.malformedJSON }
    guard !candidates.isEmpty else { throw TripCandidateDecodeError.emptyCandidates }
    return candidates
  }

  private static func jsonArraySlice(in text: String) -> String? {
    var index = text.startIndex
    while index < text.endIndex {
      guard text[index] == "[" else {
        index = text.index(after: index)
        continue
      }
      let contentsStart = text.index(after: index)
      guard let firstContent = text[contentsStart...].firstIndex(where: { !$0.isWhitespace }),
        text[firstContent] == "{" || text[firstContent] == "]"
      else {
        index = contentsStart
        continue
      }
      if let close = matchingArrayClose(in: text, openingAt: index) {
        return String(text[index...close])
      }
      index = contentsStart
    }
    return nil
  }

  /// Finds the matching close bracket while honoring JSON strings and escapes, so
  /// prose with a stray `[` cannot steal the candidate array's closing bracket.
  private static func matchingArrayClose(in text: String, openingAt open: String.Index) -> String.Index? {
    var depth = 0
    var inString = false
    var escaped = false
    var index = open
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else {
        switch character {
        case "\"": inString = true
        case "[": depth += 1
        case "]":
          depth -= 1
          if depth == 0 { return index }
        default: break
        }
      }
      index = text.index(after: index)
    }
    return nil
  }
}

public enum TripCandidateDecodeError: Error, Equatable, LocalizedError, Sendable {
  case missingJSONArray
  case malformedJSON
  case emptyCandidates

  public var errorDescription: String? {
    switch self {
    case .missingJSONArray: "This result does not contain a candidate JSON array."
    case .malformedJSON: "This candidate JSON is malformed. Nothing was imported."
    case .emptyCandidates: "This result has no candidates. Nothing was imported."
    }
  }
}

extension TripIdea {
  /// Review-dependent boundary: materializes exactly one human-approved candidate
  /// as a freeform `.considering` stop; placement hints remain uncommitted prose.
  @discardableResult
  public static func commit(
    candidate: TripCandidate,
    into tripID: Trip.ID,
    in db: Database
  ) throws -> TripIdea {
    let id = UUID()
    let tripIdea = TripIdea(
      id: id,
      tripID: tripID,
      ideaID: nil,
      inlineTitle: candidate.name,
      inlineNote: candidate.rationale,
      status: .considering,
      shortlistRank: candidate.priority ?? 0
    )
    try TripIdea.insert { TripIdea.Draft(tripIdea) }.execute(db)
    guard let committed = try TripIdea.find(id).fetchOne(db) else { throw TripError.creationFailed }
    return committed
  }

  /// Link one reviewed recommendation candidate to its confirmed pool place. This is
  /// intentionally a one-column write: `inlineNote` is the AI's trip-specific
  /// rationale and must survive resolution beside the shared place facts (ADR-0036
  /// D3 / ADR-0037 D4).
  @discardableResult
  public static func attachResolvedIdea(
    _ ideaID: Idea.ID,
    to candidateStopID: TripIdea.ID,
    in db: Database
  ) throws -> TripIdea? {
    guard try TripIdea.find(candidateStopID).fetchOne(db) != nil else { return nil }
    try TripIdea.find(candidateStopID)
      .update { $0.ideaID = #bind(ideaID) }
      .execute(db)
    return try TripIdea.find(candidateStopID).fetchOne(db)
  }

  /// Reverse of `attachResolvedIdea`: unlink the resolved place so a mis-tapped
  /// candidate returns to the unresolved state and can be re-resolved on the map.
  /// When `deletingOrphanedIdea` is set (the caller knows this resolution *minted*
  /// the idea), the just-detached idea is also removed if nothing else still points
  /// at it — cleaning up the throwaway record a wrong tap created without touching a
  /// pool idea the resolution merely reused.
  @discardableResult
  public static func detachResolvedIdea(
    from candidateStopID: TripIdea.ID,
    deletingOrphanedIdea: Bool = false,
    in db: Database
  ) throws -> TripIdea? {
    guard let existing = try TripIdea.find(candidateStopID).fetchOne(db) else { return nil }
    let detachedIdeaID = existing.ideaID
    try TripIdea.find(candidateStopID)
      .update { $0.ideaID = #bind(nil) }
      .execute(db)
    if
      deletingOrphanedIdea,
      let detachedIdeaID,
      try !Idea.isReferenced(detachedIdeaID, in: db)
    {
      try Idea.find(detachedIdeaID).delete().execute(db)
    }
    return try TripIdea.find(candidateStopID).fetchOne(db)
  }
}

extension Idea {
  /// True if any persisted row still points at this idea through the loose `ideaID`
  /// links (ADR-0007's single-FK sharing rule). Guards the mis-tap cleanup in
  /// `TripIdea.detachResolvedIdea` so a freshly-minted idea is deleted only when
  /// nothing — another stop, a stay, a photo, a tag, an interest, an evaluation —
  /// still depends on it.
  public static func isReferenced(_ ideaID: Idea.ID, in db: Database) throws -> Bool {
    if try TripIdea.where({ $0.ideaID.eq(ideaID) }).fetchCount(db) > 0 { return true }
    if try TripStay.where({ $0.ideaID.eq(ideaID) }).fetchCount(db) > 0 { return true }
    if try ImageAsset.where({ $0.ideaID.eq(ideaID) }).fetchCount(db) > 0 { return true }
    if try IdeaTag.where({ $0.ideaID.eq(ideaID) }).fetchCount(db) > 0 { return true }
    if try IdeaInterest.where({ $0.ideaID.eq(ideaID) }).fetchCount(db) > 0 { return true }
    if try IdeaEvaluation.where({ $0.ideaID.eq(ideaID) }).fetchCount(db) > 0 { return true }
    return false
  }
}

extension HandoffSession {
  /// A recommendation set can only enter evaluation after at least one reviewed
  /// candidate has a durable trip-stop link. Keeping this decision beside the
  /// device-local payload prevents entry points from disagreeing about readiness.
  public var hasCommittedRecommendationCandidates: Bool {
    candidateLinks.contains { $0.tripIdeaID != nil }
  }

  public func recommendationCandidates() throws -> [TripCandidate] {
    guard let candidatePayload else { return [] }
    return try JSONDecoder().decode([TripCandidate].self, from: Data(candidatePayload.utf8))
  }

  public mutating func storeRecommendationCandidates(_ candidates: [TripCandidate]) throws {
    candidatePayload = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
    let linkedTripIdeaIDs = Dictionary(uniqueKeysWithValues: candidateLinks.map { ($0.candidateID, $0.tripIdeaID) })
    candidateLinks = candidates.map {
      HandoffCandidateLink(candidateID: $0.id, tripIdeaID: linkedTripIdeaIDs[$0.id] ?? nil)
    }
  }

  public mutating func link(candidateID: TripCandidate.ID, to tripIdeaID: TripIdea.ID) {
    guard let index = candidateLinks.firstIndex(where: { $0.candidateID == candidateID }) else { return }
    candidateLinks[index].tripIdeaID = tripIdeaID
  }

  public mutating func replaceRecommendationCandidate(_ candidate: TripCandidate) throws {
    var candidates = try recommendationCandidates()
    guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
    candidates[index] = candidate
    try storeRecommendationCandidates(candidates)
  }
}

private extension String {
  var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
