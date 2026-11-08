import Foundation
import SQLiteData

/// A dated statement in the travel party's own words (ADR-0053 D2).
/// `ideaID` is loose so a note outlives a deleted place; `placeName` preserves its
/// subject. The only real foreign key is `travelPartyID`.
@Table
public struct TasteNote: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var travelPartyID: TravelParty.ID
  public var plannerID: Planner.ID?
  public var ideaID: Idea.ID?
  public var placeName: String?
  public var body: String
  public var source: TasteNoteSource
  public var sourceDetail: String?
  public var notedAt: Date

  public init(
    id: UUID,
    travelPartyID: TravelParty.ID,
    plannerID: Planner.ID? = nil,
    ideaID: Idea.ID? = nil,
    placeName: String? = nil,
    body: String,
    source: TasteNoteSource = .planner,
    sourceDetail: String? = nil,
    notedAt: Date
  ) {
    self.id = id
    self.travelPartyID = travelPartyID
    self.plannerID = plannerID
    self.ideaID = ideaID
    self.placeName = placeName
    self.body = body
    self.source = source
    self.sourceDetail = sourceDetail
    self.notedAt = notedAt
  }
}

public enum TasteNoteSource: String, Codable, CaseIterable, Equatable, QueryBindable, Sendable {
  case planner
  case conversation
}

/// A note's subject cannot represent an idea without the name that survives its deletion.
public enum TasteNoteSubject: Equatable, Sendable {
  case general
  case place(name: String, ideaID: Idea.ID?)
}

extension TasteNote {
  public static func newestFirst(_ notes: [TasteNote]) -> [TasteNote] {
    notes.sorted {
      $0.notedAt == $1.notedAt ? $0.id.uuidString < $1.id.uuidString : $0.notedAt > $1.notedAt
    }
  }

  public var subject: TasteNoteSubject {
    guard let placeName, !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .general
    }
    return .place(name: placeName, ideaID: ideaID)
  }

  /// Intentionally lossy: caps outbound context at 80 notes or 12,000 characters;
  /// the final line reports the number omitted so readers never mistake it for the full record.
  public static func promptLines(
    notes: [TasteNote], planners: [Planner], limit: Int = 80, characterLimit: Int = 12_000
  ) -> [String] {
    let plannerNames = Dictionary(planners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    let ordered = notes.sorted {
      if $0.notedAt != $1.notedAt { return $0.notedAt > $1.notedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MMM yyyy"
    guard !ordered.isEmpty else { return [] }
    var lines = ["These are the travel party's own words. Argue from named examples; do not recite them."]
    var used = lines[0].count
    var included = 0
    for note in ordered {
      guard included < Swift.max(0, limit) else { break }
      let who = note.plannerID.flatMap { plannerNames[$0] } ?? "Both of us"
      let date = formatter.string(from: note.notedAt)
      let place: String
      if case let .place(name, _) = note.subject { place = " about \(name)" }
      else { place = " (general travel taste)" }
      let line = "- \(date) · \(who)\(place): \(note.body)"
      guard used + line.count + 1 <= Swift.max(0, characterLimit) else { break }
      lines.append(line)
      used += line.count + 1
      included += 1
    }
    let omitted = ordered.count - included
    if omitted > 0 { lines.append("…\(omitted) taste note\(omitted == 1 ? "" : "s") omitted by the context limit.") }
    return lines
  }
}
