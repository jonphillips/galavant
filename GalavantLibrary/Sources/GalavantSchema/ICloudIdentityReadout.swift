import Foundation

/// A CloudKit-free snapshot of the identity information visible on this device.
public struct ICloudIdentityReadout: Equatable, Sendable {
  public enum DeviceIdentity: Equatable, Sendable {
    case recordName(String)
    case unavailable(String)
  }

  public enum ShareSource: Equatable, Sendable {
    case notShared
    case server
    case storedCopy(fetchError: String)
    case unavailable(String)
  }

  public enum Role: String, Equatable, Sendable {
    case owner
    case participant
    case other
  }

  public enum Permission: String, Equatable, Sendable {
    case readOnly
    case readWrite
    case none
    case unknown
  }

  public enum AcceptanceStatus: String, Equatable, Sendable {
    case accepted
    case pending
    case removed
    case unknown
  }

  public enum ParticipantMatch: Equatable, Sendable {
    case recordName
    case ownerPlaceholder
    case noMatch
  }

  public struct Participant: Equatable, Sendable {
    public let recordName: String?
    public let formattedName: String?
    public let lookupInfo: String?
    public let role: Role
    public let permission: Permission
    public let acceptanceStatus: AcceptanceStatus
    public let hasICloudAccount: Bool
    public let isCurrentUser: Bool
    public let isOnlyCurrentUserParticipant: Bool

    public init(
      recordName: String?,
      formattedName: String?,
      lookupInfo: String?,
      role: Role,
      permission: Permission,
      acceptanceStatus: AcceptanceStatus,
      hasICloudAccount: Bool,
      isCurrentUser: Bool,
      isOnlyCurrentUserParticipant: Bool = false
    ) {
      self.recordName = recordName
      self.formattedName = formattedName
      self.lookupInfo = lookupInfo
      self.role = role
      self.permission = permission
      self.acceptanceStatus = acceptanceStatus
      self.hasICloudAccount = hasICloudAccount
      self.isCurrentUser = isCurrentUser
      self.isOnlyCurrentUserParticipant = isOnlyCurrentUserParticipant
    }
  }

  public let deviceIdentity: DeviceIdentity
  public let build: String
  public let shareSource: ShareSource
  public let participants: [Participant]

  public init(
    deviceIdentity: DeviceIdentity,
    build: String,
    shareSource: ShareSource,
    participants: [Participant]
  ) {
    self.deviceIdentity = deviceIdentity
    self.build = build
    self.shareSource = shareSource
    self.participants = participants
  }

  public func matchStatus(for participant: Participant) -> ParticipantMatch {
    if case let .recordName(deviceRecordName) = deviceIdentity,
      participant.recordName == deviceRecordName
    {
      return .recordName
    }
    if participant.isCurrentUser && participant.recordName == Self.ownerPlaceholder {
      return .ownerPlaceholder
    }
    return .noMatch
  }

  public var summary: String {
    guard shareSource != .notShared else { return "The travel party isn't shared" }
    if let participant = participants.first(where: { matchStatus(for: $0) == .recordName }) {
      return "This device is in the share as \(participant.formattedName ?? participant.recordName ?? "—")"
    }
    if participants.contains(where: { matchStatus(for: $0) == .ownerPlaceholder }) {
      return "This device appears only as the owner placeholder"
    }
    return "This device isn't in the share"
  }

  public func matchDescription(for participant: Participant) -> String {
    switch matchStatus(for: participant) {
    case .recordName: "record name"
    case .ownerPlaceholder: "owner placeholder"
    case .noMatch: "no"
    }
  }

  public var text: String {
    var lines = [summary]
    lines.append("Build: \(build)")
    switch deviceIdentity {
    case let .recordName(recordName):
      lines.append("This device record name: \(recordName)")
    case let .unavailable(reason):
      lines.append("This device record name: unavailable (\(reason))")
    }
    switch shareSource {
    case .notShared:
      lines.append("Share: not shared")
    case .server:
      lines.append("Share: fetched from the server")
    case let .storedCopy(fetchError):
      lines.append("Share: stored copy (server fetch failed: \(fetchError))")
    case let .unavailable(reason):
      lines.append("Share: unavailable (\(reason))")
    }
    for (index, participant) in participants.enumerated() {
      lines.append("Participant \(index + 1):")
      lines.append("  Name: \(participant.formattedName ?? "—")")
      lines.append("  Record name: \(participant.recordName ?? "—")")
      lines.append("  Lookup info: \(participant.lookupInfo ?? "—")")
      lines.append("  Role: \(participant.role.rawValue)")
      lines.append("  Permission: \(participant.permission.rawValue)")
      lines.append("  Acceptance: \(participant.acceptanceStatus.rawValue)")
      lines.append("  Has iCloud account: \(participant.hasICloudAccount ? "yes" : "no")")
      lines.append("  Current user: \(participant.isCurrentUser ? "yes" : "no")")
      lines.append("  Matches this device: \(matchDescription(for: participant))")
      lines.append(
        "  Listed in share.participants: \(participant.isOnlyCurrentUserParticipant ? "no" : "yes")"
      )
      if participant.recordName == Self.ownerPlaceholder {
        lines.append("  Owner placeholder: yes")
      }
    }
    return lines.joined(separator: "\n")
  }

  public static let ownerPlaceholder = "__defaultOwner__"
}
