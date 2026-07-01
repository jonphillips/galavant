import CloudKit
import Dependencies
import Foundation
import SQLiteData

/// CloudKit sync control surface, ported from YesChef's device-verified M4 milestone
/// (see jon-platform `docs/ios/persistence-and-sync.md`). It owns the three pieces the
/// SQLiteData sync story needs beyond simply constructing an engine:
///
/// 1. a **persisted-local** enablement gate (a launch-arg alone vanishes on any
///    non-Xcode relaunch, so the engine silently never starts — the "enablement trap"),
/// 2. the **consumer-side redrain** on scene activation (the pending table drains only
///    inside `start()`; a running engine never re-reads it), and
/// 3. the **`PendingRecordZoneChange` poll** the share extension waits on before
///    `completeRequest`, so a stopped-engine write's deferred pending row is durably
///    persisted before the host tears the extension process down.
public enum GalavantCloudSync {
  public enum BootstrapMode: Sendable {
    /// Local-only: no engine constructed (previews/tests).
    case disabled
    /// Construct the engine. `startImmediately: false` = "construct, don't run"
    /// (every share-extension writer, and the app until the gate says otherwise).
    case configured(startImmediately: Bool)
  }

  public enum StartResult: Equatable, Sendable {
    case disabled
    case unavailable(String)
    case started
    case failed(String)
  }

  public enum PendingRecordZoneRedrainResult: Equatable, Sendable {
    case disabled
    case noPendingChanges
    case unavailable(String)
    case restarted
    case failed(String)
  }

  public static let containerIdentifier = "iCloud.com.jonphillips.galavant"
  public static let enabledDefaultsKey = "GalavantCloudKitSyncEnabled"
  public static let enabledEnvironmentKey = "GALAVANT_CLOUDKIT_SYNC_ENABLED"
  public static let enabledLaunchArgument = "-GalavantCloudKitSyncEnabled"

  // MARK: Enablement gate

  public static func isManuallyEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    defaults.bool(forKey: enabledDefaultsKey)
      || isEnabledViaLaunchEnvironment(environment: environment, arguments: arguments)
  }

  static func isEnabledViaLaunchEnvironment(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    environment[enabledEnvironmentKey] == "1"
      || environment[enabledEnvironmentKey]?.lowercased() == "true"
      || arguments.contains(enabledLaunchArgument)
  }

  /// Mirrors the dev-only launch flag into the persistent defaults domain.
  ///
  /// The launch argument/environment lives only in the volatile `NSArgumentDomain`, so
  /// it is present solely for launches from Xcode. Without persisting it, a normal
  /// relaunch (tapping the app icon, or being handed back from the share extension) sees
  /// `isManuallyEnabled == false`, the engine never starts, and pending record-zone
  /// changes written by the share extension never drain. Call at app `init()`.
  public static func persistManualEnablementFromLaunchEnvironment(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    guard isEnabledViaLaunchEnvironment(environment: environment, arguments: arguments)
    else { return }
    defaults.set(true, forKey: enabledDefaultsKey)
  }

  // MARK: Engine construction

  public static func makeSyncEngine(
    for database: any DatabaseWriter,
    startImmediately: Bool
  ) throws -> SyncEngine {
    try SyncEngine(
      for: database,
      tables:
        TravelParty.self,
        Idea.self,
        Planner.self,
        IdeaInterest.self,
        MapRegion.self,
        Tag.self,
        IdeaTag.self,
        Trip.self,
        TripIdea.self,
        TripRegion.self,
        ImageAsset.self,
        TripStay.self,
        TripDayRegion.self,
        IdeaEvaluation.self,
        TravelProfile.self,
      containerIdentifier: containerIdentifier,
      startImmediately: startImmediately
    )
  }

  // MARK: Start (cold launch)

  /// Start the engine only if the gate is on and iCloud is available. The app
  /// constructs the engine stopped at bootstrap, then calls this from `init()`.
  public static func startIfManuallyEnabled() async -> StartResult {
    guard isManuallyEnabled()
    else { return .disabled }

    do {
      let accountStatus = try await CKContainer(identifier: containerIdentifier).accountStatus()
      guard accountStatus == .available
      else { return .unavailable(accountStatus.syncDescription) }

      @Dependency(\.defaultSyncEngine) var syncEngine
      try await syncEngine.start()
      return .started
    } catch {
      return .failed(String(describing: error))
    }
  }

  // MARK: Redrain (scene activation — consumer side)

  /// On scene `.active`, if the gate is on and the pending table is non-empty, cycle
  /// `stop()`+`start()` so `start()` re-drains the pending `PendingRecordZoneChange`
  /// rows a share extension left behind. Gated on the count so it fires only right
  /// after a share, not on every foreground.
  public static func redrainPendingRecordZoneChangesIfManuallyEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments,
    database providedDatabase: (any DatabaseWriter)? = nil,
    accountStatus providedAccountStatus: (() async throws -> CKAccountStatus)? = nil,
    stopSyncEngine: (() -> Void)? = nil,
    startSyncEngine: (() async throws -> Void)? = nil
  ) async -> PendingRecordZoneRedrainResult {
    guard isManuallyEnabled(defaults: defaults, environment: environment, arguments: arguments)
    else { return .disabled }

    do {
      let database: any DatabaseWriter
      if let providedDatabase {
        database = providedDatabase
      } else {
        @Dependency(\.defaultDatabase) var defaultDatabase
        database = defaultDatabase
      }
      let pendingChangeCount = try await pendingRecordZoneChangeCount(in: database)
      guard pendingChangeCount > 0
      else { return .noPendingChanges }

      let accountStatus: CKAccountStatus
      if let providedAccountStatus {
        accountStatus = try await providedAccountStatus()
      } else {
        accountStatus = try await CKContainer(identifier: containerIdentifier).accountStatus()
      }
      guard accountStatus == .available
      else { return .unavailable(accountStatus.syncDescription) }

      if let stopSyncEngine {
        stopSyncEngine()
      } else {
        @Dependency(\.defaultSyncEngine) var syncEngine
        syncEngine.stop()
      }
      if let startSyncEngine {
        try await startSyncEngine()
      } else {
        @Dependency(\.defaultSyncEngine) var syncEngine
        try await syncEngine.start()
      }
      return .restarted
    } catch {
      return .failed(String(describing: error))
    }
  }

  // MARK: Pending-change poll (producer side — the completeRequest race)

  public static func pendingRecordZoneChangeCount(in database: any DatabaseWriter) async throws -> Int {
    try await database.read { db in
      try pendingRecordZoneChangeCount(in: db)
    }
  }

  public static func pendingRecordZoneChangeCount(in db: Database) throws -> Int {
    try #sql(
      """
      SELECT COUNT(*)
      FROM "sqlitedata_icloud"."sqlitedata_icloud_pendingRecordZoneChanges"
      """,
      as: Int.self
    )
    .fetchOne(db) ?? 0
  }

  /// Bounded-poll the pending-changes table until it exceeds `previousCount` (the count
  /// captured *before* the write) or the timeout elapses. The share extension awaits
  /// this before `completeRequest` so the stopped engine's deferred pending row is
  /// durably persisted before the host kills the process. Times out rather than blocks
  /// forever so a save never hangs.
  public static func waitForPendingRecordZoneChanges(
    in database: any DatabaseWriter,
    exceeding previousCount: Int,
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(25)
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while true {
      let currentCount = try await pendingRecordZoneChangeCount(in: database)
      if currentCount > previousCount {
        return true
      }
      guard clock.now < deadline else {
        return false
      }
      try await Task.sleep(for: pollInterval)
    }
  }
}

extension CKAccountStatus {
  var syncDescription: String {
    switch self {
    case .available: "available"
    case .couldNotDetermine: "couldNotDetermine"
    case .noAccount: "noAccount"
    case .restricted: "restricted"
    case .temporarilyUnavailable: "temporarilyUnavailable"
    @unknown default: "unknown"
    }
  }
}
