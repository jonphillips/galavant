import Dependencies
import Foundation

public enum HandoffStatus: String, Codable, Equatable, Sendable {
  case awaitingReturn
  /// At least one reviewed row was committed. A candidate handoff is row-grain, so
  /// this deliberately means "touched", not "every returned row was consumed".
  case imported
}

public struct HandoffCandidateLink: Codable, Equatable, Sendable {
  public let candidateID: UUID
  public var tripIdeaID: UUID?

  public init(candidateID: UUID, tripIdeaID: UUID? = nil) {
    self.candidateID = candidateID
    self.tripIdeaID = tripIdeaID
  }
}

/// A device-local handoff session. The app owns the meaning of the source/task
/// strings; this small spine treats them as opaque tokens for its later lift.
public struct HandoffSession: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let sourceType: String
  public let sourceID: UUID
  public let taskType: String
  public let scopeKey: String?
  public let createdAt: Date
  public var importedAt: Date?
  public var status: HandoffStatus
  public let schemaVersion: Int
  public let exportedPrompt: String
  public var candidatePayload: String?
  public var candidateLinks: [HandoffCandidateLink]

  public init(
    id: UUID = UUID(),
    sourceType: String,
    sourceID: UUID,
    taskType: String,
    scopeKey: String? = nil,
    createdAt: Date = .now,
    importedAt: Date? = nil,
    status: HandoffStatus = .awaitingReturn,
    schemaVersion: Int = 1,
    exportedPrompt: String,
    candidatePayload: String? = nil,
    candidateLinks: [HandoffCandidateLink] = []
  ) {
    self.id = id
    self.sourceType = sourceType
    self.sourceID = sourceID
    self.taskType = taskType
    self.scopeKey = scopeKey
    self.createdAt = createdAt
    self.importedAt = importedAt
    self.status = status
    self.schemaVersion = schemaVersion
    self.exportedPrompt = exportedPrompt
    self.candidatePayload = candidatePayload
    self.candidateLinks = candidateLinks
  }

  public var header: String { "GV-HANDOFF: \(id.uuidString)" }

  enum CodingKeys: String, CodingKey {
    case id, sourceType, sourceID, taskType, scopeKey, createdAt, importedAt, status, schemaVersion
    case exportedPrompt, candidatePayload, candidateLinks
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sourceType = try values.decode(String.self, forKey: .sourceType)
    sourceID = try values.decode(UUID.self, forKey: .sourceID)
    taskType = try values.decode(String.self, forKey: .taskType)
    scopeKey = try values.decodeIfPresent(String.self, forKey: .scopeKey)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt)
    status = try values.decode(HandoffStatus.self, forKey: .status)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    exportedPrompt = try values.decode(String.self, forKey: .exportedPrompt)
    candidatePayload = try values.decodeIfPresent(String.self, forKey: .candidatePayload)
    candidateLinks = try values.decodeIfPresent([HandoffCandidateLink].self, forKey: .candidateLinks) ?? []
  }
}

public struct RoutedText: Equatable, Sendable {
  public let sessionID: HandoffSession.ID
  public let text: String

  public init(sessionID: HandoffSession.ID, text: String) {
    self.sessionID = sessionID
    self.text = text
  }
}

public enum HandoffRoutingError: Error, Equatable, LocalizedError, Sendable {
  case missingToken
  case malformedToken

  public var errorDescription: String? {
    switch self {
    case .missingToken: "This result is missing its Galavant handoff token."
    case .malformedToken: "This result has an invalid Galavant handoff token."
    }
  }
}

public enum HandoffRouting {
  /// Lossless-or-loud boundary: routes a pasted response to its originating session
  /// and removes only the routing line before domain parsing.
  public static func route(_ text: String) throws -> RoutedText {
    let lines = text.components(separatedBy: .newlines)
    guard let tokenLineIndex = lines.firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("GV-HANDOFF:")
    }) else {
      throw HandoffRoutingError.missingToken
    }
    let tokenLine = lines[tokenLineIndex]
    let token = tokenLine
      .replacingOccurrences(of: "GV-HANDOFF:", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sessionID = UUID(uuidString: token) else { throw HandoffRoutingError.malformedToken }
    var routedLines = lines
    routedLines.remove(at: tokenLineIndex)
    return RoutedText(sessionID: sessionID, text: routedLines.joined(separator: "\n"))
  }
}

public struct HandoffContractMarker: Equatable, Sendable {
  public let prefix: String
  public let version: String

  public init(prefix: String, version: String) {
    self.prefix = prefix
    self.version = version
  }

  public var marker: String { "\(prefix): \(version)" }

  /// Strip the contract marker, treating a missing or *older* marker as advisory
  /// rather than fatal: the JSON decode step is the real lossless-or-loud guard, so
  /// a dropped marker line shouldn't block an otherwise-good paste. Only a marker
  /// *newer* than this build understands stays loud — that's the one case where
  /// decoding could silently misread a future schema.
  public func strippingMarker(from text: String) throws -> HandoffContractResult {
    let lines = text.components(separatedBy: .newlines)
    guard let markerLineIndex = lines.firstIndex(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\(prefix):")
    }) else {
      return HandoffContractResult(
        text: text,
        warning: "This result was missing its Galavant contract marker (\(marker)). Imported anyway — re-copy your project instructions from Settings if the results look off."
      )
    }
    let found = lines[markerLineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    var strippedLines = lines
    strippedLines.remove(at: markerLineIndex)
    let stripped = strippedLines.joined(separator: "\n")

    if found == marker {
      return HandoffContractResult(text: stripped, warning: nil)
    }
    if let foundVersion = Self.versionNumber(found),
      let knownVersion = Self.versionNumber(marker),
      foundVersion > knownVersion {
      throw HandoffContractError.unsupportedMarker(found: found, expected: marker)
    }
    return HandoffContractResult(
      text: stripped,
      warning: "This result used a different contract marker (\(found), expected \(marker)). Imported anyway — re-copy your project instructions from Settings if the results look off."
    )
  }

  /// Parse the trailing integer of a `prefix: vN` marker line (`GV-CONTRACT: v2` → 2).
  private static func versionNumber(_ markerLine: String) -> Int? {
    guard let colon = markerLine.firstIndex(of: ":") else { return nil }
    let raw = markerLine[markerLine.index(after: colon)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
    return Int(digits)
  }
}

/// The result of stripping a contract marker: the body to decode, plus an optional
/// non-blocking warning when the marker was missing or older than the current one.
public struct HandoffContractResult: Equatable, Sendable {
  public let text: String
  public let warning: String?

  public init(text: String, warning: String?) {
    self.text = text
    self.warning = warning
  }
}

public enum HandoffContractError: Error, Equatable, LocalizedError, Sendable {
  /// The pasted marker names a schema newer than this build — decoding could
  /// silently misread it, so this stays a hard stop.
  case unsupportedMarker(found: String, expected: String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedMarker(found, expected):
      "This result uses a newer Galavant contract (\(found)) than this app understands (\(expected)). Update Galavant, or re-copy your project instructions from Settings."
    }
  }
}

public struct HandoffSessionStore: Sendable {
  public var save: @Sendable (HandoffSession) throws -> Void
  public var session: @Sendable (HandoffSession.ID) -> HandoffSession?
  public var sessions: @Sendable () -> [HandoffSession]
}

extension HandoffSessionStore: DependencyKey {
  public static let liveValue = HandoffSessionStore(
    save: { session in
      var sessions = HandoffSessionStore.loadSessions()
      sessions[session.id] = session
      let data = try JSONEncoder().encode(sessions)
      UserDefaults.standard.set(data, forKey: HandoffSessionStore.storageKey)
    },
    session: { id in HandoffSessionStore.loadSessions()[id] },
    sessions: { Array(HandoffSessionStore.loadSessions().values) }
  )

  public static let testValue = HandoffSessionStore(
    save: { _ in },
    session: { _ in nil },
    sessions: { [] }
  )

  private static let storageKey = "GalavantDeviceLocalHandoffSessions"

  private static func loadSessions() -> [UUID: HandoffSession] {
    guard
      let data = UserDefaults.standard.data(forKey: storageKey),
      let sessions = try? JSONDecoder().decode([UUID: HandoffSession].self, from: data)
    else { return [:] }
    return sessions
  }
}

extension DependencyValues {
  public var handoffSessionStore: HandoffSessionStore {
    get { self[HandoffSessionStore.self] }
    set { self[HandoffSessionStore.self] = newValue }
  }
}
