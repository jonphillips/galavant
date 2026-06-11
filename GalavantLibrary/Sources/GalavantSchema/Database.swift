import Dependencies
import Foundation
import IssueReporting
import SQLiteData

public enum GalavantStorage {
  public static let appGroupID = "group.com.jonphillips.galavant"

  public static func liveDatabasePath() -> String {
    if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupID
    ) {
      return container.appending(path: "galavant.sqlite").path(percentEncoded: false)
    }
    reportIssue("App group container unavailable; falling back to Application Support")
    let directory = URL.applicationSupportDirectory.appending(
      path: "Galavant", directoryHint: .isDirectory
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "galavant.sqlite").path(percentEncoded: false)
  }
}

extension DependencyValues {
  public mutating func bootstrapDatabase(startSyncEngine: Bool = true) throws {
    @Dependency(\.context) var context
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.attachMetadatabase()
    }
    let database: any DatabaseWriter =
      if context == .live {
        try SQLiteData.defaultDatabase(
          path: GalavantStorage.liveDatabasePath(), configuration: configuration
        )
      } else {
        try SQLiteData.defaultDatabase(configuration: configuration)
      }
    var migrator = DatabaseMigrator()
    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif
    migrator.registerMigration("Create ideas table") { db in
      try #sql(
        """
        CREATE TABLE "ideas" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "notes" TEXT NOT NULL DEFAULT '',
          "regionName" TEXT,
          "latitude" REAL,
          "longitude" REAL
        ) STRICT
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create households table; add householdID to ideas") { db in
      try #sql(
        """
        CREATE TABLE "households" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT ''
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "ideas"
        ADD COLUMN "householdID" TEXT REFERENCES "households"("id") ON DELETE CASCADE
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_ideas_on_householdID" ON "ideas"("householdID")
        """
      )
      .execute(db)
    }
    try migrator.migrate(database)
    defaultDatabase = database
    if context == .live, startSyncEngine {
      defaultSyncEngine = try SyncEngine(
        for: database,
        tables: Household.self, Idea.self
      )
    }
  }
}
