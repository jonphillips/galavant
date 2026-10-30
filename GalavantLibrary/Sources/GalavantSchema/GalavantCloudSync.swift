import CloudKit
import CloudSyncKit
import Dependencies
import SQLiteData

/// Galavant's binding of the shared `CloudSync` core (jon-platform ADR-0003). The
/// sync-control logic — the enablement gate, gated start, scene redrain, and the
/// `PendingRecordZoneChange` poll — now lives once in `CloudSyncKit`, shared with Yes
/// Chef (both apps had forked it line-for-line). This thin facade holds the two things
/// that are genuinely galavant's: its `CloudSyncConfiguration` (container id + gate
/// keys) and `makeSyncEngine`, which lists the app's synced `@Table` types and so can't
/// lift. Everything else forwards to `CloudSync`, passing `configuration`.
public enum GalavantCloudSync {
  /// The per-app constants — the only thing that differed from Yes Chef's copy.
  public static let configuration = CloudSyncConfiguration(
    containerIdentifier: "iCloud.com.jonphillips.galavant",
    enabledDefaultsKey: "GalavantCloudKitSyncEnabled",
    enabledEnvironmentKey: "GALAVANT_CLOUDKIT_SYNC_ENABLED",
    enabledLaunchArgument: "-GalavantCloudKitSyncEnabled",
    restoreRequiresManualEnablementDefaultsKey: "GalavantCloudKitSyncRestoreRequiresManualEnablement"
  )

  /// Per-app identity and migration entry point for CloudSyncKit's shared backup flow.
#if DEBUG
  private static let backupDisplayName = "Galavant Dev"
  private static let backupFilenamePrefix = "Galavant-Dev-Backup-"
#else
  private static let backupDisplayName = "Galavant"
  private static let backupFilenamePrefix = "Galavant-Backup-"
#endif

  public static let databaseBackupConfiguration = DatabaseBackupConfiguration(
    displayName: backupDisplayName,
    backupFilenamePrefix: backupFilenamePrefix,
    preRestoreFilenamePrefix: "Galavant-PreRestore-",
    restoreStagingFilenamePrefix: "Galavant-Restore-",
    identifyingTableNames: ["travelParties", "ideas"],
    declaredSchemaVersion: GalavantDatabaseMigrations.schemaVersion,
    lastPreRestoreDefaultsKey: "GalavantDatabaseBackupLastPreRestorePath",
    cloudSync: configuration,
    liveStoreURL: { try GalavantStorage.liveDatabaseURL() },
    migrate: { try DependencyValues.migrateRestoreCandidate(at: $0) }
  )

  public typealias BootstrapMode = CloudSync.BootstrapMode
  public typealias StartResult = CloudSync.StartResult
  public typealias PendingRecordZoneRedrainResult = CloudSync.PendingRecordZoneRedrainResult

  /// The synced tables shared by the failure report, retry, and the live engine.
  private static let syncTables = GalavantSyncTables(
    containerIdentifier: configuration.containerIdentifier,
    TravelParty.self, Idea.self, Planner.self, IdeaInterest.self, MapRegion.self, Tag.self,
    IdeaTag.self, Trip.self, TripIdea.self, CalendarReconciliationLedgerEntry.self,
    CalendarPlanRepair.self, CalendarPlanRepairResolution.self, CalendarTripConstraint.self,
    CalendarIgnoredEvent.self, TripRegion.self, ImageAsset.self, RegionImage.self,
    TripStay.self, TripDocument.self, TripDayRegion.self, TripDayTimeZone.self,
    TripDayNote.self, TripAlternativeGroup.self, IdeaEvaluation.self, TravelProfile.self
  )

  public static var syncedTables: SyncedTables { syncTables.syncedTables }

  public static var containerIdentifier: String { configuration.containerIdentifier }

  // MARK: Enablement gate (forwarded)

  public static func isManuallyEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    CloudSync.isManuallyEnabled(
      configuration: configuration, defaults: defaults, environment: environment,
      arguments: arguments
    )
  }

  public static func setManuallyEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
    CloudSync.setManuallyEnabled(enabled, configuration: configuration, defaults: defaults)
  }

  public static func isDisabledByRestore(defaults: UserDefaults = .standard) -> Bool {
    CloudSync.isDisabledByRestore(configuration: configuration, defaults: defaults)
  }

  public static func persistManualEnablementFromLaunchEnvironment(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    CloudSync.persistManualEnablementFromLaunchEnvironment(
      configuration: configuration, defaults: defaults, environment: environment,
      arguments: arguments
    )
  }

  // MARK: Start / redrain / pending (forwarded)

  public static func startIfManuallyEnabled() async -> StartResult {
    await CloudSync.startIfManuallyEnabled(configuration: configuration)
  }

  public static func redrainPendingRecordZoneChangesIfManuallyEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments,
    database providedDatabase: (any DatabaseWriter)? = nil,
    accountStatus providedAccountStatus: (() async throws -> CKAccountStatus)? = nil,
    stopSyncEngine: (() -> Void)? = nil,
    startSyncEngine: (() async throws -> Void)? = nil
  ) async -> PendingRecordZoneRedrainResult {
    await CloudSync.redrainPendingRecordZoneChangesIfManuallyEnabled(
      configuration: configuration, defaults: defaults, environment: environment,
      arguments: arguments, database: providedDatabase,
      accountStatus: providedAccountStatus, stopSyncEngine: stopSyncEngine,
      startSyncEngine: startSyncEngine
    )
  }

  public static func pendingRecordZoneChangeCount(in database: any DatabaseWriter) async throws -> Int {
    try await CloudSync.pendingRecordZoneChangeCount(in: database)
  }

  public static func pendingRecordZoneChangeCount(in db: Database) throws -> Int {
    try CloudSync.pendingRecordZoneChangeCount(in: db)
  }

  public static func waitForPendingRecordZoneChanges(
    in database: any DatabaseWriter,
    exceeding previousCount: Int,
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(25)
  ) async throws -> Bool {
    try await CloudSync.waitForPendingRecordZoneChanges(
      in: database, exceeding: previousCount, timeout: timeout, pollInterval: pollInterval
    )
  }

  public static func syncFailureReport(
    in database: any DatabaseWriter,
    isEngineRunning: Bool,
    isSendingChanges: Bool,
    isFetchingChanges: Bool,
    now: Date = .now,
    verdictCache: SyncFailureVerdictCache
  ) async throws -> SyncFailureReportResult {
    try await CloudSync.syncFailureReport(
      in: database, tables: syncedTables, isEngineRunning: isEngineRunning,
      isSendingChanges: isSendingChanges, isFetchingChanges: isFetchingChanges,
      now: now, verdictCache: verdictCache
    )
  }

  public static func requeue(
    recordType: String,
    primaryKeys: [String],
    in database: any DatabaseWriter,
    verdictCache: SyncFailureVerdictCache
  ) async throws -> SyncRequeueResult {
    try await CloudSync.requeue(
      recordType: recordType, primaryKeys: primaryKeys, tables: syncedTables,
      in: database, verdictCache: verdictCache
    )
  }

  // MARK: Engine construction (domain-bound — stays here)

  /// Construct the sync engine over galavant's synced tables. This is the one method
  /// that can't lift: it names the app's `@Table` types. Every product a synced table
  /// belongs to must be registered here (and in `project.yml` deps) or a regenerate
  /// silently drops it.
  public static func makeSyncEngine(
    for database: any DatabaseWriter,
    startImmediately: Bool
  ) throws -> SyncEngine {
    try syncTables.makeSyncEngine(for: database, startImmediately: startImmediately)
  }
}

/// Captures one heterogeneous table-type pack for both matching and engine creation,
/// so the failure report cannot name a different table set from SQLiteData.
// The immutable factory captures only table metatypes and a container identifier.
private struct GalavantSyncTables: @unchecked Sendable {
  let syncedTables: SyncedTables
  private let engineFactory: (any DatabaseWriter, Bool) throws -> SyncEngine

  init<each T: PrimaryKeyedTable & SendableMetatype>(
    containerIdentifier: String,
    _ tables: repeat (each T).Type
  ) where repeat (each T).PrimaryKey: SendableMetatype,
          repeat (each T).PrimaryKey.QueryOutput: IdentifierStringConvertible & SendableMetatype,
          repeat (each T).TableColumns: SendableMetatype,
          repeat (each T).TableColumns.PrimaryColumn: WritableTableColumnExpression {
    syncedTables = SyncedTables(repeat each tables)
    engineFactory = { database, startImmediately in
      try SyncEngine(
        for: database,
        tables: repeat each tables,
        containerIdentifier: containerIdentifier,
        startImmediately: startImmediately
      )
    }
  }

  func makeSyncEngine(for database: any DatabaseWriter, startImmediately: Bool) throws -> SyncEngine {
    try engineFactory(database, startImmediately)
  }
}
