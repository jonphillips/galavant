import CloudKit
import Dependencies
import GalavantSchema
import Observation
import SQLiteData
import os

/// Drives the Settings screen's travel-party sharing (moved here from the Ideas
/// toolbar). The substantive sync work lives in SQLiteData's `SyncEngine`; this is
/// the thin shell that ensures the default travel party exists and hands its
/// `SharedRecord` to the system `CloudSharingView`.
@MainActor
@Observable
final class SettingsModel {
  /// The in-flight CloudKit share, presented as the system sharing sheet.
  var sharedRecord: SharedRecord?

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.defaultSyncEngine) private var syncEngine

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
