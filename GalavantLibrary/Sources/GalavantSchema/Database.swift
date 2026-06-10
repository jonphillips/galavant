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
  public mutating func bootstrapDatabase() throws {
    @Dependency(\.context) var context
    let database: any DatabaseWriter =
      if context == .live {
        try SQLiteData.defaultDatabase(path: GalavantStorage.liveDatabasePath())
      } else {
        try SQLiteData.defaultDatabase()
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
    try migrator.migrate(database)
    defaultDatabase = database
  }
}
