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

  /// Lossless-or-loud boundary: a stale or missing contract marker is rejected
  /// before the caller can decode a return against the wrong schema.
  public func strippingMarker(from text: String) throws -> String {
    let lines = text.components(separatedBy: .newlines)
    guard let markerLineIndex = lines.firstIndex(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\(prefix):")
    }) else {
      throw HandoffContractError.missingMarker(expected: marker)
    }
    guard lines[markerLineIndex].trimmingCharacters(in: .whitespacesAndNewlines) == marker else {
      throw HandoffContractError.outdatedMarker(expected: marker)
    }
    var strippedLines = lines
    strippedLines.remove(at: markerLineIndex)
    return strippedLines.joined(separator: "\n")
  }
}

public enum HandoffContractError: Error, Equatable, LocalizedError, Sendable {
  case missingMarker(expected: String)
  case outdatedMarker(expected: String)

  public var errorDescription: String? {
    switch self {
    case let .missingMarker(expected), let .outdatedMarker(expected):
      "Your project instructions are out of date. Re-copy them from Settings (\(expected))."
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
