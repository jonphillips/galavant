import Foundation

public enum SeedVerdict: Equatable, Hashable, Sendable {
  case core
  case considering
  case declined
  case deferred
  case unrecognized(String)

  public init(_ value: String?) {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      self = .considering
      return
    }
    switch value.lowercased() {
    case "core": self = .core
    case "considering": self = .considering
    case "declined": self = .declined
    case "deferred": self = .deferred
    default: self = .unrecognized(value)
    }
  }

  public var originalValue: String {
    switch self {
    case .core: "core"
    case .considering: "considering"
    case .declined: "declined"
    case .deferred: "deferred"
    case let .unrecognized(value): value
    }
  }
}

public struct SeedTrip: Equatable, Sendable {
  public var lengthDays: Int?
  public var year: Int?
  public var quarter: Int?
  public var summary: String?
}

public struct SeedBase: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var locality: String?
  public var searchHint: String?
  public var region: String?
  public var checkInDay: Int
  public var checkOutDay: Int
  public var why: String?
  public var placeNotes: String?
  public var bookAhead: Bool
}

public struct SeedPlace: Equatable, Identifiable, Sendable {
  public var id: UUID { candidate.id }
  public var candidate: TripCandidate
  public var verdict: SeedVerdict
  public var reason: String?
  public var futureTrip: String?
  public var placeNotes: String?
  public var group: String?
  public var normalizedKind: IdeaKind? { IdeaKind(seedKind: candidate.kind) }

  public init(
    candidate: TripCandidate,
    verdict: SeedVerdict,
    reason: String? = nil,
    futureTrip: String? = nil,
    placeNotes: String? = nil,
    group: String? = nil
  ) {
    self.candidate = candidate
    self.verdict = verdict
    self.reason = reason
    self.futureTrip = futureTrip
    self.placeNotes = placeNotes
    self.group = group
  }
}

public struct SeedReturn: Equatable, Sendable {
  public var narrative: String
  public var trip: SeedTrip
  public var bases: [SeedBase]
  public var places: [SeedPlace]
  public var warnings: [String]

  public static func decode(_ text: String) throws -> SeedReturn {
    guard let marker = text.split(separator: "\n", omittingEmptySubsequences: false)
      .lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "GV-SEED" })
    else { throw SeedReturnDecodeError.missingSeedMarker }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let narrative = lines[..<marker].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = lines[(marker + 1)...].joined(separator: "\n")
    guard let object = Self.jsonObjectSlice(in: tail) else {
      throw SeedReturnDecodeError.missingJSONObject
    }
    let normalized = object
      .replacingOccurrences(of: "“", with: "\"")
      .replacingOccurrences(of: "”", with: "\"")
      .replacingOccurrences(of: "‘", with: "'")
      .replacingOccurrences(of: "’", with: "'")
    guard let root = (try? JSONSerialization.jsonObject(with: Data(normalized.utf8))) as? [String: Any]
    else { throw SeedReturnDecodeError.malformedJSON }

    let seedTrip = decodeTrip(root)
    let fallback = root.string("summary") ?? seedTrip.summary
    let finalNarrative = narrative.isEmpty ? (fallback ?? "") : narrative
    let (bases, warnings) = decodeBases(root["bases"] as? [[String: Any]] ?? [], lengthDays: seedTrip.lengthDays)
    let places = decodePlaces(root["places"] as? [[String: Any]] ?? [])
    guard !bases.isEmpty || !places.isEmpty else { throw SeedReturnDecodeError.emptySeed }
    return SeedReturn(narrative: finalNarrative, trip: seedTrip, bases: bases, places: places, warnings: warnings)
  }

  private static func decodeTrip(_ root: [String: Any]) -> SeedTrip {
    let object = root["trip"] as? [String: Any] ?? [:]
    return SeedTrip(
      lengthDays: object.integer("length_days"), year: object.integer("year"),
      quarter: object.integer("quarter"), summary: object.string("summary")
    )
  }

  private static func decodeBases(_ rawBases: [[String: Any]], lengthDays: Int?) -> ([SeedBase], [String]) {
    var warnings: [String] = []
    let bases = rawBases.enumerated().compactMap { index, object -> SeedBase? in
      guard
        let name = object.string("name"),
        let checkIn = object.integer("check_in_day"),
        let checkOut = object.integer("check_out_day"),
        TripStay.isValidSpan(checkInDay: checkIn, checkOutDay: checkOut),
        lengthDays.map({ checkOut <= $0 }) ?? true
      else {
        warnings.append("Base \(index + 1) was omitted because it needs a name and a valid day span.")
        return nil
      }
      return SeedBase(
        id: UUID(), name: name, locality: object.string("locality"),
        searchHint: object.string("search_hint"), region: object.string("region"),
        checkInDay: checkIn, checkOutDay: checkOut, why: object.string("why"),
        placeNotes: object.string("place_notes"), bookAhead: object.bool("book_ahead") ?? false
      )
    }
    return (bases, warnings)
  }

  private static func decodePlaces(_ rawPlaces: [[String: Any]]) -> [SeedPlace] {
    rawPlaces.map { object in
      let candidate = TripCandidate(
        name: object.string("name"), locality: object.string("locality"),
        searchHint: object.string("search_hint"), why: object.string("why"),
        fit: object.string("fit"), kind: object.string("kind"), visit: object.string("visit"),
        priority: object.integer("priority"), dayRef: object.stringOrNumber("day_ref"),
        placementAfter: object.string("placement_after"), bookAhead: object.bool("book_ahead")
      )
      return SeedPlace(
        candidate: candidate,
        verdict: SeedVerdict(object.string("verdict")),
        reason: object.string("reason"), futureTrip: object.string("future_trip"),
        placeNotes: object.string("place_notes"), group: object.string("group")
      )
    }
  }

  private static func jsonObjectSlice(in text: String) -> String? {
    var index = text.startIndex
    while index < text.endIndex {
      guard text[index] == "{" else {
        index = text.index(after: index)
        continue
      }
      if let close = matchingObjectClose(in: text, openingAt: index) {
        return String(text[index...close])
      }
      return String(text[index...])
    }
    return nil
  }

  private static func matchingObjectClose(in text: String, openingAt open: String.Index) -> String.Index? {
    var depth = 0
    var inString = false
    var escaped = false
    var index = open
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
      } else {
        switch character {
        case "\"": inString = true
        case "{": depth += 1
        case "}":
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

public enum SeedReturnDecodeError: Error, Equatable, LocalizedError, Sendable {
  case missingSeedMarker
  case missingJSONObject
  case malformedJSON
  case emptySeed

  public var errorDescription: String? {
    switch self {
    case .missingSeedMarker: "This result does not contain a GV-SEED marker. Nothing was imported."
    case .missingJSONObject: "This result does not contain a seed JSON object. Nothing was imported."
    case .malformedJSON: "This seed JSON is malformed. Nothing was imported."
    case .emptySeed: "This result has no valid bases or places. Nothing was imported."
    }
  }
}

private extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? {
    guard let value = self[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func stringOrNumber(_ key: String) -> String? {
    if let value = string(key) { return value }
    guard let number = self[key] as? NSNumber else { return nil }
    return number.stringValue
  }

  func integer(_ key: String) -> Int? {
    if let value = self[key] as? Int { return value }
    guard let value = self[key] as? String else { return nil }
    return Int(value)
  }

  func bool(_ key: String) -> Bool? {
    if let value = self[key] as? Bool { return value }
    guard let value = self[key] as? String else { return nil }
    return switch value.lowercased() {
    case "true", "yes": true
    case "false", "no": false
    default: nil
    }
  }
}
