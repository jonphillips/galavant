import Foundation

/// The "am I actually syncing?" surface as a single domain value (STYLE §3): raw
/// CloudKit-sync signals folded into one display state, the same total-conversion
/// shape as `Certainty`/`Schedule`. A two-person household needs to *know* whether
/// it shares a pool or silently keeps two private ones — this ends that silent
/// degradation (docs/M5-EXECUTION.md → M5-sync).
///
/// Deliberately **domain-free**: it knows nothing about `Idea`/`Trip`/travel parties,
/// and — critically — imports no CloudKit. Feed it plain values (the app maps
/// `CKAccountStatus` → `SyncAccountStatus` at the boundary). Every SQLiteData+CloudKit
/// app wants this same surface, so it's destined for a later rename-and-move to
/// `jon-platform` like `WebExtractorKit`/`GalavantAI` — keep it clean, no premature
/// package.
public struct SyncHealth: Equatable, Sendable {
  /// The user gate: sync stays off until manually enabled
  /// (`GalavantCloudSync.isManuallyEnabled`).
  public var isManuallyEnabled: Bool
  /// The iCloud account availability, mapped off `CKAccountStatus` at the boundary.
  public var account: SyncAccountStatus
  /// Whether SQLiteData's `SyncEngine` is currently running (`syncEngine.isRunning`).
  public var isEngineRunning: Bool
  /// Outbound rows not yet pushed to CloudKit
  /// (`GalavantCloudSync.pendingRecordZoneChangeCount`). The "still uploading" signal.
  public var pendingChangeCount: Int
  /// The last error surfaced by a start attempt or a signal read, if any.
  public var lastError: String?

  public init(
    isManuallyEnabled: Bool,
    account: SyncAccountStatus,
    isEngineRunning: Bool,
    pendingChangeCount: Int,
    lastError: String? = nil
  ) {
    self.isManuallyEnabled = isManuallyEnabled
    self.account = account
    self.isEngineRunning = isEngineRunning
    self.pendingChangeCount = pendingChangeCount
    self.lastError = lastError
  }

  /// The reducer: raw signals → one display state. Precedence is deliberate —
  /// the gate is the first gate, then a missing/broken iCloud account (which is
  /// *local-only*, not an error — the user just isn't signed in), then a genuine
  /// start failure, then a not-yet-running engine (also local-only), then whether
  /// there's still outbound work. Total: every input combination lands somewhere.
  public var displayStatus: SyncDisplayStatus {
    guard isManuallyEnabled else { return .disabled }
    guard account.isAvailable else { return .localOnly(reason: account.localOnlyReason) }
    if let lastError { return .error(lastError) }
    guard isEngineRunning else { return .localOnly(reason: "sync hasn’t started yet") }
    guard pendingChangeCount == 0 else { return .syncing(pending: pendingChangeCount) }
    return .upToDate
  }
}

/// The iCloud account availability, a CloudKit-free mirror of `CKAccountStatus`
/// (mapped at the app boundary — see `GalavantCloudSync`). Kept here so the reducer
/// and its tests never import CloudKit.
public enum SyncAccountStatus: Equatable, Sendable, CaseIterable {
  case available
  case noAccount
  case restricted
  case couldNotDetermine
  case temporarilyUnavailable
  case unknown

  public var isAvailable: Bool { self == .available }

  /// The reason shown after "On this device only — " when the account can't sync.
  /// `available` has no reason (it isn't local-only) but returns a generic string
  /// so the property stays total.
  public var localOnlyReason: String {
    switch self {
    case .available: "sync is available"
    case .noAccount: "no iCloud account"
    case .restricted: "iCloud is restricted"
    case .couldNotDetermine: "iCloud status unavailable"
    case .temporarilyUnavailable: "iCloud temporarily unavailable"
    case .unknown: "iCloud unavailable"
    }
  }
}

/// The display state a `SyncHealth` folds to — the value the Settings row renders.
/// Presentation strings live here (domain-free, like `CertaintyStage.label`); the
/// dot color is a pure SwiftUI concern and stays in the view.
public enum SyncDisplayStatus: Equatable, Sendable {
  /// The gate is off — the row becomes the enable affordance.
  case disabled
  /// iCloud can't sync (no account, restricted, …) or the engine isn't running.
  /// The couple sees two private pools; surface the `reason`.
  case localOnly(reason: String)
  /// Outbound changes are still uploading.
  case syncing(pending: Int)
  /// Everything is pushed and the account is live.
  case upToDate
  /// A start attempt or signal read failed; carries the raw error string.
  case error(String)

  /// The one-line row text (the colored dot's caption).
  public var summary: String {
    switch self {
    case .disabled: "Sync is off"
    case let .localOnly(reason): "On this device only — \(reason)"
    case .syncing: "Syncing…"
    case .upToDate: "Up to date"
    case .error: "Sync error"
    }
  }
}
