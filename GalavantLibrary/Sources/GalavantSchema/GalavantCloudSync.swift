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
    enabledLaunchArgument: "-GalavantCloudKitSyncEnabled"
  )

  public typealias BootstrapMode = CloudSync.BootstrapMode
  public typealias StartResult = CloudSync.StartResult
  public typealias PendingRecordZoneRedrainResult = CloudSync.PendingRecordZoneRedrainResult

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

  // MARK: Engine construction (domain-bound — stays here)

  /// Construct the sync engine over galavant's synced tables. This is the one method
  /// that can't lift: it names the app's `@Table` types. Every product a synced table
  /// belongs to must be registered here (and in `project.yml` deps) or a regenerate
  /// silently drops it.
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
        CalendarReconciliationLedgerEntry.self,
        CalendarPlanRepair.self,
        CalendarPlanRepairResolution.self,
        CalendarTripConstraint.self,
        TripRegion.self,
        ImageAsset.self,
        TripStay.self,
        TripDayRegion.self,
        IdeaEvaluation.self,
        TravelProfile.self,
      containerIdentifier: configuration.containerIdentifier,
      startImmediately: startImmediately
    )
  }
}
