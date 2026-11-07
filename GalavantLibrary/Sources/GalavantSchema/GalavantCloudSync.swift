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
    TripDayNote.self, TripAlternativeGroup.self, IdeaEvaluation.self, TravelProfile.self, TasteNote.self
  )

  public static var syncedTables: SyncedTables { syncTables.syncedTables }

  /// The columns each synced table writes to CloudKit, captured from the same table pack
  /// as `syncedTables` and the engine. `CloudKitSchemaCoverageTests` holds this against
  /// `cloudkit-expected-fields.txt`, the list `testflight` checks against Production.
  public static var syncedRecordSchemas: [SyncedRecordSchema] { syncTables.recordSchemas }

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
    @Dependency(\.syncEngineAvailable) var available
    guard available else { return .failed("Sync engine unavailable until next launch") }
    @Dependency(\.syncStartGate) var gate
    @Dependency(\.defaultSyncEngine) var engine
    return await gate.run {
      await CloudSync.startIfManuallyEnabled(configuration: configuration, startSyncEngine: {
        try await gate.start { try await engine.start() }
      })
    }
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
    @Dependency(\.syncEngineAvailable) var available
    guard available else { return .failed("Sync engine unavailable until next launch") }
    @Dependency(\.syncStartGate) var gate
    @Dependency(\.defaultSyncEngine) var engine
    return await gate.run {
      await CloudSync.redrainPendingRecordZoneChangesIfManuallyEnabled(
        configuration: configuration, defaults: defaults, environment: environment,
        arguments: arguments, database: providedDatabase,
        accountStatus: providedAccountStatus, stopSyncEngine: stopSyncEngine,
        startSyncEngine: {
          try await gate.start {
            if let startSyncEngine { try await startSyncEngine() }
            else { try await engine.start() }
          }
        }
      )
    }
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

/// The CloudKit fields one synced table's records carry, as SQLiteData writes them.
public struct SyncedRecordSchema: Sendable, Equatable {
  public struct Column: Sendable, Equatable {
    public var name: String
    /// A `Data` column syncs as a `CKAsset` under its name plus a `<name>_hash` field.
    public var isAsset: Bool
  }

  public var recordType: String
  public var columns: [Column]

  /// Every field SQLiteData writes for this record type: the record-level modification
  /// time, and per writable column its value field (an asset and its hash for `Data`)
  /// and its `sqlitedata_icloud_userModificationTime_<column>` field. SQLiteData writes
  /// the modification-time field even for a nil column, so the schema needs it from the
  /// first record; the value field appears only once a non-nil value syncs.
  public var cloudKitFields: [String] {
    var fields = [Self.modificationTimeKey]
    for column in columns {
      fields.append(column.name)
      if column.isAsset { fields.append("\(column.name)_hash") }
      fields.append("\(Self.modificationTimeKey)_\(column.name)")
    }
    return fields
  }

  /// SQLiteData's `CKRecord.userModificationTimeKey`, which it doesn't export.
  static let modificationTimeKey = "sqlitedata_icloud_userModificationTime"
}

/// Captures one heterogeneous table-type pack for both matching and engine creation,
/// so the failure report cannot name a different table set from SQLiteData.
private struct GalavantSyncTables: Sendable {
  let syncedTables: SyncedTables
  let recordSchemas: [SyncedRecordSchema]
  private let engineFactory: @Sendable (any DatabaseWriter, Bool) throws -> SyncEngine

  init<each T: PrimaryKeyedTable & SendableMetatype>(
    containerIdentifier: String,
    _ tables: repeat (each T).Type
  ) where repeat (each T).PrimaryKey: SendableMetatype,
          repeat (each T).PrimaryKey.QueryOutput: IdentifierStringConvertible & SendableMetatype,
          repeat (each T).TableColumns: SendableMetatype,
          repeat (each T).TableColumns.PrimaryColumn: WritableTableColumnExpression {
    syncedTables = SyncedTables(repeat each tables)
    var recordSchemas: [SyncedRecordSchema] = []
    for table in repeat each tables { recordSchemas.append(recordSchema(table)) }
    self.recordSchemas = recordSchemas
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

/// Walks `writableColumns`, the same columns SQLiteData's `CKRecord.update(with:)` writes.
private func recordSchema<T: PrimaryKeyedTable>(_ type: T.Type) -> SyncedRecordSchema {
  var columns: [SyncedRecordSchema.Column] = []
  for column in T.TableColumns.writableColumns {
    func open<Root, Value>(_ column: some WritableTableColumnExpression<Root, Value>) {
      // `Data` binds as `.blob`, which SQLiteData uploads as an asset plus a hash.
      let output = Value.QueryOutput.self
      let isAsset = output == Data.self || output == Data?.self
        || output == [UInt8].self || output == [UInt8]?.self
      columns.append(SyncedRecordSchema.Column(name: column.name, isAsset: isAsset))
    }
    open(column)
  }
  return SyncedRecordSchema(recordType: T.tableName, columns: columns)
}
