import CloudKit
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData
import Sharing

/// Owns the Settings "Planners" surface: the travel party's voters, with rename
/// and delete so stale or duplicate planner rows (from earlier testing/sync) can
/// be pruned — the "bunch of stale voters" Jon hit on the idea rows (dogfood).
/// The view stays presentation (STYLE thin-views rule).
@MainActor
@Observable
final class PlannerManagementModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll(Planner.order(by: \.displayName)) var planners
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""
  var iCloudIdentityReadout: ICloudIdentityReadout?
  var isRefreshingICloudIdentity = false

  /// This device's own planner — never deletable from here.
  var currentPlannerID: Planner.ID? { UUID(uuidString: currentPlannerIDString) }
  var hasCurrentPlanner: Bool {
    guard let currentPlannerID else { return false }
    return planners.contains { $0.id == currentPlannerID }
  }

  /// Bind this device to an existing synced planner. The identity stays local.
  func setCurrentPlanner(_ planner: Planner) {
    $currentPlannerIDString.withLock { $0 = planner.id.uuidString }
  }

  /// How many ratings a planner has actually cast — the signal for whether a row
  /// is a real voter or a stale empty duplicate.
  func voteCount(for planner: Planner) -> Int {
    interests.filter { $0.plannerID == planner.id && $0.level != nil }.count
  }

  func rename(_ planner: Planner, to name: String) {
    withErrorReporting {
      try database.write { db in
        try Planner.rename(id: planner.id, to: name, in: db)
      }
    }
  }

  /// Delete a planner and the ratings it left. A no-op guard keeps this device's
  /// own planner safe — deleting it would strand the device's identity.
  func delete(_ planner: Planner) {
    guard planner.id != currentPlannerID else { return }
    withErrorReporting {
      try database.write { db in
        try Planner.deletePlanner(id: planner.id, in: db)
      }
    }
  }

  func refreshICloudIdentity() async {
    guard !isRefreshingICloudIdentity else { return }
    isRefreshingICloudIdentity = true
    defer { isRefreshingICloudIdentity = false }

    let deviceIdentity: ICloudIdentityReadout.DeviceIdentity
    do {
      let recordID = try await CKContainer(identifier: GalavantCloudSync.containerIdentifier)
        .userRecordID()
      deviceIdentity = .recordName(recordID.recordName)
    } catch {
      deviceIdentity = .unavailable(error.localizedDescription)
    }

    do {
      let storedShare = try await database.read { db -> CKShare? in
        guard let travelParty = try TravelParty.order(by: \.id).fetchOne(db) else { return nil }
        return try SyncMetadata.find(travelParty.syncMetadataID).fetchOne(db)?.share
      }
      guard let storedShare else {
        iCloudIdentityReadout = ICloudIdentityReadout(
          deviceIdentity: deviceIdentity,
          shareSource: .notShared,
          participants: []
        )
        return
      }

      let database: CKDatabase =
        storedShare.recordID.zoneID.ownerName == CKCurrentUserDefaultName
        ? CKContainer(identifier: GalavantCloudSync.containerIdentifier).privateCloudDatabase
        : CKContainer(identifier: GalavantCloudSync.containerIdentifier).sharedCloudDatabase

      do {
        let record = try await database.record(for: storedShare.recordID)
        guard let freshShare = record as? CKShare else {
          throw ICloudIdentityReadoutError.fetchedRecordWasNotShare
        }
        iCloudIdentityReadout = ICloudIdentityReadout(
          deviceIdentity: deviceIdentity,
          shareSource: .server,
          participants: Self.participants(in: freshShare)
        )
      } catch {
        iCloudIdentityReadout = ICloudIdentityReadout(
          deviceIdentity: deviceIdentity,
          shareSource: .storedCopy(fetchError: error.localizedDescription),
          participants: Self.participants(in: storedShare)
        )
      }
    } catch {
      iCloudIdentityReadout = ICloudIdentityReadout(
        deviceIdentity: deviceIdentity,
        shareSource: .unavailable(error.localizedDescription),
        participants: []
      )
    }
  }

  private static func participants(in share: CKShare) -> [ICloudIdentityReadout.Participant] {
    var cloudParticipants = share.participants
    if let currentUser = share.currentUserParticipant,
      !cloudParticipants.contains(where: { $0.isEqual(currentUser) })
    {
      cloudParticipants.append(currentUser)
    }
    return cloudParticipants.map { participant in
      let identity = participant.userIdentity
      let formattedName = identity.nameComponents.map {
        PersonNameComponentsFormatter().string(from: $0)
      }
      let lookupInfo = [identity.lookupInfo?.emailAddress, identity.lookupInfo?.phoneNumber]
        .compactMap { $0 }
        .joined(separator: ", ")
      let role: ICloudIdentityReadout.Role = switch participant.role {
      case .owner: .owner
      case .privateUser: .participant
      default: .other
      }
      let permission: ICloudIdentityReadout.Permission = switch participant.permission {
      case .readOnly: .readOnly
      case .readWrite: .readWrite
      case .none: .none
      default: .unknown
      }
      let acceptanceStatus: ICloudIdentityReadout.AcceptanceStatus = switch participant.acceptanceStatus {
      case .accepted: .accepted
      case .pending: .pending
      case .removed: .removed
      default: .unknown
      }
      return ICloudIdentityReadout.Participant(
        recordName: identity.userRecordID?.recordName,
        formattedName: formattedName.flatMap { $0.isEmpty ? nil : $0 },
        lookupInfo: lookupInfo.isEmpty ? nil : lookupInfo,
        role: role,
        permission: permission,
        acceptanceStatus: acceptanceStatus,
        hasICloudAccount: identity.hasiCloudAccount,
        isCurrentUser: share.currentUserParticipant?.isEqual(participant) ?? false
      )
    }
  }
}

private enum ICloudIdentityReadoutError: Error, LocalizedError {
  case fetchedRecordWasNotShare

  var errorDescription: String? {
    "CloudKit returned a record that wasn't a share."
  }
}
