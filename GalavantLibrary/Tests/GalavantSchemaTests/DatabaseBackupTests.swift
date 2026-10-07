import CloudSyncKit
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import GRDB
import SQLiteData
import Testing

@Suite(.dependencies {
  try $0.bootstrapDatabase()
  $0.uuid = .incrementing
})
struct DatabaseBackupTests {
  @Dependency(\.defaultDatabase) var database

  @Test func configurationIdentifiesGalavantAndDeclaresRegisteredSchemaVersion() throws {
    let configuration = GalavantCloudSync.databaseBackupConfiguration
    #expect(configuration.displayName == "Galavant")
    #expect(configuration.identifyingTableNames == ["travelParties", "ideas"])
    // The facade derives this version directly from the registered list, so it cannot drift.
    #expect(configuration.declaredSchemaVersion == GalavantDatabaseMigrations.makeMigrator().migrations.count)

    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let nonGalavantURL = directory.appending(path: "other.sqlite")
    let otherDatabase = try DatabaseQueue(path: nonGalavantURL.path)
    try otherDatabase.write { db in try db.execute(sql: "CREATE TABLE recipes (id TEXT)") }
    try otherDatabase.close()
    #expect(throws: DatabaseBackup.BackupError.notAppBackup("Galavant")) {
      try DatabaseBackup.validateAppSchema(in: nonGalavantURL, configuration: configuration)
    }
  }

  @Test func snapshotPrepareAndRestorePreserveImageAndTripDocumentBytes() async throws {
    try await database.write { db in
      let party = try TravelParty.ensureDefault(in: db)
      let ideaID = UUID()
      try Idea.insert {
        Idea.Draft(Idea(id: ideaID, name: "Museum", travelPartyID: party.id))
      }.execute(db)
      let imageBytes = Data([0, 1, 2, 127, 128, 254, 255])
      _ = try ImageAsset.store(
        ideaID: ideaID, display: imageBytes, thumbnail: Data([9, 8, 7]),
        sourceURL: "https://example.com/image.jpg", id: UUID(), in: db
      )
      let trip = try Trip.create(name: "Copenhagen", in: db)
      _ = try TripDocument.add(
        tripID: trip.id, title: "Research", body: "exact document bytes: café",
        origin: .pasted, now: Date(timeIntervalSince1970: 1_700_000_000), in: db
      )
    }

    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = GalavantCloudSync.databaseBackupConfiguration
    let snapshotURL = directory.appending(path: "snapshot.sqlite")
    let snapshot = try await DatabaseBackup.snapshot(
      from: database, to: snapshotURL, configuration: configuration
    )
    let prepared = try await DatabaseBackup.prepareRestore(
      from: snapshot.fileURL,
      to: directory.appending(path: "prepared.sqlite"),
      currentSchemaVersion: configuration.declaredSchemaVersion,
      configuration: configuration,
      migrate: configuration.migrate
    )

    let restoredStoreURL = directory.appending(path: "restored.sqlite")
    let emptyStore = try DatabaseQueue(path: restoredStoreURL.path)
    try emptyStore.close()
    try DatabaseBackup.replaceLiveStore(
      at: restoredStoreURL,
      with: prepared,
      syncMetadataURL: directory.appending(path: "sync-metadata.sqlite")
    )
    let restoredStore = try DatabaseQueue(path: restoredStoreURL.path)
    defer { try? restoredStore.close() }
    try await restoredStore.read { db in
      let display = try Data.fetchOne(
        db,
        sql: "SELECT display FROM imageAssets WHERE ideaID = (SELECT id FROM ideas WHERE name = 'Museum')"
      )
      let thumbnail = try Data.fetchOne(
        db,
        sql: "SELECT thumbnail FROM imageAssets WHERE ideaID = (SELECT id FROM ideas WHERE name = 'Museum')"
      )
      let body = try Data.fetchOne(
        db,
        sql: "SELECT CAST(body AS BLOB) FROM tripDocuments WHERE tripID = (SELECT id FROM trips WHERE name = 'Copenhagen')"
      )
      #expect(display == Data([0, 1, 2, 127, 128, 254, 255]))
      #expect(thumbnail == Data([9, 8, 7]))
      #expect(body == Data("exact document bytes: café".utf8))
    }
  }

  @Test func restoreMigratesSnapshotFromPreviousMigrationPrefix() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = GalavantCloudSync.databaseBackupConfiguration
    let oldStoreURL = directory.appending(path: "old.sqlite")
    let oldStore = try DatabaseQueue(path: oldStoreURL.path)
    let migrator = GalavantDatabaseMigrations.makeMigrator()
    try migrator.migrate(oldStore)
    let latestMigration = try #require(migrator.migrations.last)
    try await oldStore.write { db in
      try db.execute(sql: "DROP TABLE tripDocuments")
      try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: [latestMigration]
      )
    }
    try oldStore.close()

    let snapshotURL = directory.appending(path: "older-backup.sqlite")
    let source = try DatabaseQueue(path: oldStoreURL.path)
    let snapshot = try await DatabaseBackup.snapshot(
      from: source, to: snapshotURL, configuration: configuration
    )
    try source.close()
    let snapshotDatabase = try DatabaseQueue(path: snapshot.fileURL.path)
    try await snapshotDatabase.write { db in
      try db.execute(sql: "PRAGMA user_version = \(configuration.declaredSchemaVersion - 1)")
    }
    try snapshotDatabase.close()

    let prepared = try await DatabaseBackup.prepareRestore(
      from: snapshot.fileURL,
      to: directory.appending(path: "migrated.sqlite"),
      currentSchemaVersion: configuration.declaredSchemaVersion,
      configuration: configuration,
      migrate: configuration.migrate
    )
    let migrated = try DatabaseQueue(path: prepared.fileURL.path)
    defer { try? migrated.close() }
    let hasTripDocuments = try await migrated.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tripDocuments')"
      ) ?? false
    }
    #expect(hasTripDocuments)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "GalavantBackupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
