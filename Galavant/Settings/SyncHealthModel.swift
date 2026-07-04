import CloudKit
import Dependencies
import GalavantSchema
import Observation
import SQLiteData

/// The thin observable shell that feeds the pure `SyncHealth` reducer live signals
/// (docs/M5-EXECUTION.md → M5-sync, slice 2). It reads the gate, the iCloud account
/// status, the `SyncEngine`'s observable running state, and the pending-change count,
/// folds them into a `SyncHealth`, and exposes the folded `displayStatus` for the
/// Settings row. All the decision logic lives in the tested value type; this only
/// gathers and orchestrates.
@MainActor
@Observable
final class SyncHealthModel {
  private(set) var health: SyncHealth
  /// True while a start attempt (Try again / Enable) is in flight — drives the
  /// button's progress affordance.
  private(set) var isStarting = false

  /// The last error from a *start attempt* (launch is discarded; Try again / Enable
  /// capture theirs). Held separately so a routine `refresh()` — which only reads
  /// live account/pending signals — never clobbers it, and so it survives until the
  /// next start attempt supersedes it.
  private var lastStartError: String?

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.defaultSyncEngine) private var syncEngine

  init() {
    health = SyncHealth(
      isManuallyEnabled: GalavantCloudSync.isManuallyEnabled(),
      account: .couldNotDetermine,
      isEngineRunning: false,
      pendingChangeCount: 0
    )
  }

  var displayStatus: SyncDisplayStatus { health.displayStatus }

  /// Live-observed sync activity. Reading the `SyncEngine`'s observable getter from
  /// the view lets a `.onChange` drive a `refresh()` the moment a sync cycle finishes,
  /// so the row flips from "Syncing…" to "Up to date" as the pending count drains.
  var isSynchronizing: Bool { syncEngine.isSynchronizing }

  /// Gather the live signals and fold them into `health`. Cheap and idempotent —
  /// safe to call on appear, on scene `.active`, on `DatabaseChange`, and whenever a
  /// sync cycle ends.
  func refresh() async {
    let isManuallyEnabled = GalavantCloudSync.isManuallyEnabled()
    let isEngineRunning = syncEngine.isRunning
    let account = await currentAccountStatus()
    // The pending-changes table only exists once sync has run; querying it while the
    // gate is off can throw "no such table", so skip it — the status is `.disabled`
    // regardless.
    let pending = isManuallyEnabled ? await currentPendingCount() : 0

    health = SyncHealth(
      isManuallyEnabled: isManuallyEnabled,
      account: account,
      isEngineRunning: isEngineRunning,
      pendingChangeCount: pending,
      lastError: lastStartError
    )
  }

  /// Turn the gate on (the row is the enable affordance when sync is off), start the
  /// engine, then refresh.
  func enableSyncButtonTapped() async {
    GalavantCloudSync.setManuallyEnabled(true)
    await start()
  }

  /// Re-run the same start the app runs at launch, capturing its error, then refresh.
  func tryAgainButtonTapped() async {
    await start()
  }

  private func start() async {
    isStarting = true
    defer { isStarting = false }
    switch await GalavantCloudSync.startIfManuallyEnabled() {
    case let .failed(message):
      lastStartError = message
    case .started, .disabled, .unavailable:
      // A clean start (or a still-unavailable account, which the reducer surfaces as
      // local-only) clears any stale start error.
      lastStartError = nil
    }
    await refresh()
  }

  private func currentAccountStatus() async -> SyncAccountStatus {
    do {
      let status = try await CKContainer(identifier: GalavantCloudSync.containerIdentifier)
        .accountStatus()
      return SyncAccountStatus(status)
    } catch {
      // A thrown status read is itself "couldn't determine" — the reducer shows it as
      // local-only, which is the honest thing to say.
      return .couldNotDetermine
    }
  }

  private func currentPendingCount() async -> Int {
    (try? await GalavantCloudSync.pendingRecordZoneChangeCount(in: database)) ?? 0
  }
}
