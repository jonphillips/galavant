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
      // The sync metadatabase needs a CloudKit container; skip it (local-only)
      // when unavailable rather than failing every database connection.
      do {
        try db.attachMetadatabase()
      } catch {
        reportIssue("Sync metadatabase unavailable; running local-only: \(error)")
      }
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
    migrator.registerMigration("Create travelParties table; add travelPartyID to ideas") { db in
      try #sql(
        """
        CREATE TABLE "travelParties" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT ''
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "ideas"
        ADD COLUMN "travelPartyID" TEXT REFERENCES "travelParties"("id") ON DELETE CASCADE
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_ideas_on_travelPartyID" ON "ideas"("travelPartyID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Pool foundation: planners, ratings, idea fields") { db in
      try #sql(
        """
        CREATE TABLE "planners" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "displayName" TEXT NOT NULL DEFAULT '',
          "travelPartyID" TEXT REFERENCES "travelParties"("id") ON DELETE CASCADE
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "ideaInterests" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "ideaID" TEXT NOT NULL REFERENCES "ideas"("id") ON DELETE CASCADE,
          "plannerID" TEXT NOT NULL,
          "level" INTEGER,
          "note" TEXT NOT NULL DEFAULT ''
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_ideaInterests_on_ideaID" ON "ideaInterests"("ideaID")
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "ideas" ADD COLUMN "kind" TEXT
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "ideas" ADD COLUMN "url" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT ''
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "ideas" ADD COLUMN "visited" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create mapRegions table") { db in
      try #sql(
        """
        CREATE TABLE "mapRegions" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "centerLatitude" REAL NOT NULL DEFAULT 0,
          "centerLongitude" REAL NOT NULL DEFAULT 0,
          "latitudeDelta" REAL NOT NULL DEFAULT 0,
          "longitudeDelta" REAL NOT NULL DEFAULT 0,
          "travelPartyID" TEXT REFERENCES "travelParties"("id") ON DELETE CASCADE
        ) STRICT
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create tags and ideaTags tables") { db in
      try #sql(
        """
        CREATE TABLE "tags" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "travelPartyID" TEXT REFERENCES "travelParties"("id") ON DELETE CASCADE
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "ideaTags" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "ideaID" TEXT NOT NULL REFERENCES "ideas"("id") ON DELETE CASCADE,
          "tagID" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_ideaTags_on_ideaID" ON "ideaTags"("ideaID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create trips and tripIdeas tables") { db in
      try #sql(
        """
        CREATE TABLE "trips" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "notes" TEXT NOT NULL DEFAULT '',
          "certaintyStage" INTEGER NOT NULL DEFAULT 0,
          "somedayRank" INTEGER NOT NULL DEFAULT 0,
          "targetYear" INTEGER,
          "targetQuarter" INTEGER,
          "startDate" TEXT,
          "lengthInDays" INTEGER NOT NULL DEFAULT 7,
          "travelPartyID" TEXT REFERENCES "travelParties"("id") ON DELETE CASCADE
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "tripIdeas" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "tripID" TEXT NOT NULL REFERENCES "trips"("id") ON DELETE CASCADE,
          "ideaID" TEXT NOT NULL,
          "status" INTEGER NOT NULL DEFAULT 0,
          "shortlistRank" INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_tripIdeas_on_tripID" ON "tripIdeas"("tripID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create tripRegions table") { db in
      try #sql(
        """
        CREATE TABLE "tripRegions" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "tripID" TEXT NOT NULL REFERENCES "trips"("id") ON DELETE CASCADE,
          "regionID" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_tripRegions_on_tripID" ON "tripRegions"("tripID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Add scheduling columns to tripIdeas") { db in
      try #sql(
        """
        ALTER TABLE "tripIdeas" ADD COLUMN "dayNumber" INTEGER
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "tripIdeas" ADD COLUMN "dayPart" INTEGER
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "tripIdeas" ADD COLUMN "startTime" TEXT
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "tripIdeas" ADD COLUMN "endTime" TEXT
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Add address and phone to ideas") { db in
      try #sql(
        """
        ALTER TABLE "ideas" ADD COLUMN "address" TEXT
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "ideas" ADD COLUMN "phone" TEXT
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Add enrichedAt to ideas") { db in
      try #sql(
        """
        ALTER TABLE "ideas" ADD COLUMN "enrichedAt" TEXT
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Add freeform-stop columns to tripIdeas (ADR-0010)") { db in
      // ideaID becomes nullable: existing rows keep their non-null value; new
      // freeform rows have ideaID NULL + inlineTitle/inlineNote non-null.
      // SQLite doesn't let us drop NOT NULL from an existing column, but a NULL
      // insert into a NOT NULL column is rejected — we need the column to accept
      // NULLs. We work around SQLite's limitation by recreating the table.
      try #sql(
        """
        CREATE TABLE "tripIdeas_new" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "tripID" TEXT NOT NULL REFERENCES "trips"("id") ON DELETE CASCADE,
          "ideaID" TEXT,
          "inlineTitle" TEXT,
          "inlineNote" TEXT,
          "status" INTEGER NOT NULL DEFAULT 0,
          "shortlistRank" INTEGER NOT NULL DEFAULT 0,
          "dayNumber" INTEGER,
          "dayPart" INTEGER,
          "startTime" TEXT,
          "endTime" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        INSERT INTO "tripIdeas_new"
          SELECT "id","tripID","ideaID",NULL,NULL,"status","shortlistRank",
                 "dayNumber","dayPart","startTime","endTime"
          FROM "tripIdeas"
        """
      )
      .execute(db)
      try #sql(
        """
        DROP TABLE "tripIdeas"
        """
      )
      .execute(db)
      try #sql(
        """
        ALTER TABLE "tripIdeas_new" RENAME TO "tripIdeas"
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_tripIdeas_on_tripID" ON "tripIdeas"("tripID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create imageAssets table") { db in
      try #sql(
        """
        CREATE TABLE "imageAssets" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "ideaID" TEXT NOT NULL REFERENCES "ideas"("id") ON DELETE CASCADE,
          "display" BLOB NOT NULL,
          "thumbnail" BLOB NOT NULL,
          "sourceURL" TEXT,
          "sortRank" INTEGER NOT NULL DEFAULT 0,
          "isHeader" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_imageAssets_on_ideaID" ON "imageAssets"("ideaID")
        """
      )
      .execute(db)
    }
    try migrator.migrate(database)
    defaultDatabase = database
    if context == .live, startSyncEngine {
      // Degrade to local-only if CloudKit is unavailable (no entitlement in an
      // unsigned dev build, or the user isn't signed into iCloud) rather than
      // crashing the app.
      do {
        defaultSyncEngine = try SyncEngine(
          for: database,
          tables: TravelParty.self, Idea.self, Planner.self, IdeaInterest.self,
          MapRegion.self, Tag.self, IdeaTag.self, Trip.self, TripIdea.self,
          TripRegion.self, ImageAsset.self
        )
      } catch {
        reportIssue("CloudKit sync unavailable; running local-only: \(error)")
      }
    }
  }
}
