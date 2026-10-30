import CloudKit
import CloudSyncKit
import Dependencies
import GalavantSchema
import Observation
import SQLiteData

/// The thin observable shell that feeds the pure `SyncHealth` reducer live signals
/// (docs/milestones/archive/M5-EXECUTION.md → M5-sync, slice 2). It reads the gate, the iCloud account
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
  @ObservationIgnored private var lastStartError: String?
  @ObservationIgnored private var syncFailureReportError: String?
  @ObservationIgnored private var syncFailureVerdictCache = SyncFailureVerdictCache()
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var refreshRequestedWhileRefreshing = false
  /// Coalesced callers wait for the follow-up refresh to finish before returning.
  @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var notUploadedRows: [SyncFailureDisplayRow] = []
  private(set) var retryingRows: Set<String> = []
  private(set) var retryError: String?

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
    guard !isRefreshing else {
      refreshRequestedWhileRefreshing = true
      await withCheckedContinuation { refreshWaiters.append($0) }
      return
    }
    isRefreshing = true
    defer {
      isRefreshing = false
      let waiters = refreshWaiters
      refreshWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
    repeat {
      refreshRequestedWhileRefreshing = false
      await refreshOnce()
    } while refreshRequestedWhileRefreshing
  }

  private func refreshOnce() async {
    let isManuallyEnabled = GalavantCloudSync.isManuallyEnabled()
    let isEngineRunning = syncEngine.isRunning
    // The download counterpart to the pending (upload) count: true while the engine is
    // pulling changes down. Without it a fresh device pulling a large pool reads
    // "Up to date" the instant the first batch lands (jon-platform ADR-0028). Only
    // meaningful while running.
    let isFetchingChanges = isEngineRunning && syncEngine.isFetchingChanges
    let account = await currentAccountStatus()
    // The pending-changes table only exists once sync has run; querying it while the
    // gate is off can throw "no such table", so skip it — the status is `.disabled`
    // regardless.
    let pending = isManuallyEnabled ? await currentPendingCount() : 0

    let failureReport: SyncFailureReport?
    if isManuallyEnabled, isEngineRunning {
      failureReport = await currentSyncFailureReport(
        isEngineRunning: true,
        isSendingChanges: syncEngine.isSendingChanges,
        isFetchingChanges: isFetchingChanges
      )
    } else {
      failureReport = nil
      syncFailureReportError = nil
    }
    if let failureReport {
      let names = (try? await Self.syncFailureDisplayNames(from: failureReport, in: database)) ?? [:]
      notUploadedRows = SyncFailureDisplayRows.build(from: failureReport, names: names)
    } else {
      notUploadedRows = []
    }
    if notUploadedRows.isEmpty {
      retryError = nil
    }

    health = SyncHealth(
      isManuallyEnabled: isManuallyEnabled,
      account: account,
      isEngineRunning: isEngineRunning,
      pendingChangeCount: pending,
      isFetchingChanges: isFetchingChanges,
      notUploadedCount: failureReport?.notUploadedCount ?? 0,
      notAppliedCount: failureReport?.notAppliedCount ?? 0,
      lastError: lastStartError ?? syncFailureReportError
    )
  }

  func isRetrying(_ row: SyncFailureDisplayRow) -> Bool {
    retryingRows.contains(row.id)
  }

  func retry(_ row: SyncFailureDisplayRow) async {
    guard !row.primaryKeys.isEmpty, retryingRows.insert(row.id).inserted else { return }
    retryError = nil
    defer { retryingRows.remove(row.id) }
    do {
      let result = try await GalavantCloudSync.requeue(
        recordType: row.recordType,
        primaryKeys: row.primaryKeys,
        in: database,
        verdictCache: syncFailureVerdictCache
      )
      syncFailureVerdictCache = result.verdictCache
      await refresh()
    } catch {
      retryError = "Couldn’t retry \(row.title): \(error.localizedDescription)"
    }
  }

  private func currentSyncFailureReport(
    isEngineRunning: Bool,
    isSendingChanges: Bool,
    isFetchingChanges: Bool
  ) async -> SyncFailureReport? {
    do {
      let result = try await GalavantCloudSync.syncFailureReport(
        in: database,
        isEngineRunning: isEngineRunning,
        isSendingChanges: isSendingChanges,
        isFetchingChanges: isFetchingChanges,
        verdictCache: syncFailureVerdictCache
      )
      syncFailureVerdictCache = result.verdictCache
      syncFailureReportError = nil
      return result.report
    } catch {
      syncFailureReportError = "Couldn’t check which records have synced."
      return nil
    }
  }

  nonisolated private static func syncFailureDisplayNames(
    from report: SyncFailureReport,
    in database: any DatabaseWriter
  ) async throws -> [SyncFailureRecordKey: SyncFailureDisplayName] {
    try await database.read { db in try SyncFailureDisplayRows.names(from: report, in: db) }
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
