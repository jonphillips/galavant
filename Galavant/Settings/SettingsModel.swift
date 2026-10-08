import CloudKit
import Dependencies
import GalavantSchema
import Observation
import SQLiteData
import os

/// Owns Settings state for travel-party sharing and the shared taste summary.
/// The sync work lives in SQLiteData's `SyncEngine`; this model ensures the
/// default travel party exists and hands its `SharedRecord` to CloudSharingView.
@MainActor
@Observable
final class SettingsModel {
  /// The in-flight CloudKit share, presented as the system sharing sheet.
  var sharedRecord: SharedRecord?
  var travelPartyID: TravelParty.ID?
  var sharedTasteSummary = "Not set"

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.defaultSyncEngine) private var syncEngine
  func refreshTravelProfile() async {
    do {
      let party = try await database.write { db in
        try TravelParty.ensureDefault(in: db)
      }
      travelPartyID = party.id
      let shared = try await database.read { db in
        let profiles = try TravelProfile.where { $0.travelPartyID.eq(party.id) }.fetchAll(db)
        return TravelProfile.survivingProfiles(travelPartyID: party.id, profiles: profiles)
          .first { $0.plannerID == nil }?.preferences ?? ""
      }
      let firstLine = shared
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines)
        .first ?? ""
      sharedTasteSummary = firstLine.isEmpty ? "Not set" : firstLine
    } catch {
      travelPartyID = nil
      sharedTasteSummary = "Not set"
    }
  }

  func shareTravelPartyButtonTapped() async {
    await withErrorReporting {
      let travelParty = try await database.write { db in
        try TravelParty.ensureDefault(in: db)
      }
      sharedRecord = try await syncEngine.share(record: travelParty) {
        $0[CKShare.SystemFieldKey.title] = "Galavant Travel Party"
      }
      #if DEBUG
        if let url = sharedRecord?.share.url {
          Logger(subsystem: "com.jonphillips.galavant", category: "Sharing")
            .warning("TRAVEL PARTY SHARE URL: \(url.absoluteString, privacy: .public)")
        }
      #endif
    }
  }
}
