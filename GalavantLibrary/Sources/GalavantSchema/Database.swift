import Dependencies
import Foundation
import IssueReporting
import SQLiteData

public enum GalavantStorage {
  public static let appGroupInfoKey = "GalavantAppGroupID"

  public static var appGroupID: String? {
    resolveAppGroupID(Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey))
  }

  public enum StorageError: Error {
    case appGroupIdentifierUnavailable
    case appGroupUnavailable
  }

  /// Resolve the configured app group without allowing a missing key to select
  /// the production store. Kept pure at the input boundary for package tests.
  public static func appGroupID(from infoDictionary: [String: Any]) -> String? {
    resolveAppGroupID(infoDictionary[appGroupInfoKey])
  }

  private static func resolveAppGroupID(_ value: Any?) -> String? {
    guard let appGroupID = value as? String, !appGroupID.isEmpty else {
      reportIssue("Missing or empty \(appGroupInfoKey) in Info.plist")
      return nil
    }
    return appGroupID
  }

  /// Backup and restore must address the shared live store, never a fallback location.
  public static func liveDatabaseURL() throws -> URL {
    guard let appGroupID else {
      throw StorageError.appGroupIdentifierUnavailable
    }
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupID
    ) else {
      throw StorageError.appGroupUnavailable
    }
    return container.appending(path: "galavant.sqlite")
  }

  public static func liveDatabasePath() throws -> String {
    try liveDatabaseURL().path(percentEncoded: false)
  }
}

extension DependencyValues {
  /// The main app: live shared store, engine constructed **stopped**. The app starts
  /// it separately via `GalavantCloudSync.startIfManuallyEnabled()` so the enablement
  /// gate + iCloud account-status check run before any networking.
  public mutating func bootstrapDatabase() throws {
    @Dependency(\.context) var context
    let syncMode: GalavantCloudSync.BootstrapMode =
      context == .live ? .configured(startImmediately: false) : .disabled
    try bootstrapDatabase(syncMode: syncMode)
  }

  /// The share extension: same live shared store, engine constructed **stopped**
  /// ("construct, don't run"). Constructing it installs SQLiteData's sync triggers so
  /// the extension's writes get `SyncMetadata` + a pending-change row the app later
  /// drains — without this the captured idea never leaves the device. It must never
  /// `start()` or network. Per CloudKit law 6 the extension target must therefore carry
  /// the iCloud container entitlement.
  public mutating func bootstrapDatabaseForShareExtension() throws {
    @Dependency(\.context) var context
    let syncMode: GalavantCloudSync.BootstrapMode =
      context == .live ? .configured(startImmediately: false) : .disabled
    try bootstrapDatabase(syncMode: syncMode)
  }

  /// Runs the registered migrations against a restore candidate without enabling sync.
  public static func migrateRestoreCandidate(at databaseURL: URL) throws {
    try withDependencies {
      $0.context = .live
    } operation: {
      var dependencies = DependencyValues()
      try dependencies.bootstrapDatabase(path: databaseURL.path, syncMode: .disabled)
      try dependencies.defaultDatabase.close()
    }
  }

  public mutating func bootstrapDatabase(
    path: String? = nil, syncMode: GalavantCloudSync.BootstrapMode
  ) throws {
    @Dependency(\.context) var context
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      // The sync metadatabase needs a CloudKit container; skip it (local-only)
      // when unavailable rather than failing every database connection.
      do {
        try db.attachMetadatabase(containerIdentifier: GalavantCloudSync.containerIdentifier)
      } catch {
        reportIssue("Sync metadatabase unavailable; running local-only: \(error)")
      }
    }
    let database: any DatabaseWriter =
      if context == .live {
        try SQLiteData.defaultDatabase(
          path: try path ?? GalavantStorage.liveDatabasePath(), configuration: configuration
        )
      } else if let path {
        try SQLiteData.defaultDatabase(path: path, configuration: configuration)
      } else {
        try SQLiteData.defaultDatabase(configuration: configuration)
      }
    let migrator = GalavantDatabaseMigrations.makeMigrator()
    try migrator.migrate(database)
    defaultDatabase = database
    if case let .configured(startImmediately) = syncMode {
      // Degrade to local-only if CloudKit is unavailable (no entitlement in an
      // unsigned dev build, or the user isn't signed into iCloud) rather than
      // crashing the app.
      do {
        defaultSyncEngine = try GalavantCloudSync.makeSyncEngine(
          for: database, startImmediately: startImmediately
        )
      } catch {
        reportIssue("CloudKit sync unavailable; running local-only: \(error)")
      }
    }
  }
}
