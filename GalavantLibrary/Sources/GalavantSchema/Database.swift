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

  public mutating func bootstrapDatabase(syncMode: GalavantCloudSync.BootstrapMode) throws {
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
          path: GalavantStorage.liveDatabasePath(), configuration: configuration
        )
      } else {
        try SQLiteData.defaultDatabase(configuration: configuration)
      }
    var migrator = DatabaseMigrator()
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
    migrator.registerMigration("Create tripStays table (ADR-0011)") { db in
      // A stay rides its trip (single real FK, cascade-deletes); ideaID is a loose,
      // optional UUID reconciled on read (ADR-0007), so no SQL FK on it. A freeform
      // stay carries inlineTitle/inlineNote with ideaID NULL.
      try #sql(
        """
        CREATE TABLE "tripStays" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "tripID" TEXT NOT NULL REFERENCES "trips"("id") ON DELETE CASCADE,
          "ideaID" TEXT,
          "inlineTitle" TEXT,
          "inlineNote" TEXT,
          "checkInDay" INTEGER NOT NULL DEFAULT 1,
          "checkOutDay" INTEGER NOT NULL DEFAULT 2,
          "checkInTime" TEXT,
          "checkOutTime" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_tripStays_on_tripID" ON "tripStays"("tripID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create tripDayRegions table (ADR-0012)") { db in
      // One of the trip's regions assigned to a day; rides the trip (single real
      // FK, cascade-deletes), regionID a loose UUID reconciled on read (ADR-0007).
      try #sql(
        """
        CREATE TABLE "tripDayRegions" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "tripID" TEXT NOT NULL REFERENCES "trips"("id") ON DELETE CASCADE,
          "dayNumber" INTEGER NOT NULL DEFAULT 1,
          "regionID" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_tripDayRegions_on_tripID" ON "tripDayRegions"("tripID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create ideaEvaluations and travelProfiles tables (ADR-0015)") { db in
      // IdeaEvaluation: rides the travel party (single real FK, cascade-deletes);
      // ideaID is a loose UUID — no SQL FK — reconciled on read (ADR-0007).
      try #sql(
        """
        CREATE TABLE "ideaEvaluations" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "travelPartyID" TEXT NOT NULL REFERENCES "travelParties"("id") ON DELETE CASCADE,
          "ideaID" TEXT NOT NULL,
          "sourceName" TEXT NOT NULL DEFAULT '',
          "kind" TEXT NOT NULL DEFAULT 'text',
          "nativeValueText" TEXT NOT NULL DEFAULT '',
          "nativeValueNumber" REAL,
          "nativeValueMax" REAL,
          "nativeDisplay" TEXT NOT NULL DEFAULT '',
          "evaluationDate" TEXT,
          "guideYear" INTEGER,
          "recordedAt" TEXT NOT NULL,
          "lastVerifiedAt" TEXT,
          "confidence" TEXT NOT NULL DEFAULT 'unverified',
          "staleness" TEXT NOT NULL DEFAULT 'unknown',
          "sourceURL" TEXT,
          "summary" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_ideaEvaluations_on_travelPartyID" ON "ideaEvaluations"("travelPartyID")
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_ideaEvaluations_on_ideaID" ON "ideaEvaluations"("ideaID")
        """
      )
      .execute(db)
      // TravelProfile: rides the travel party (single real FK, cascade-deletes);
      // plannerID is a loose optional UUID (nil = shared household profile, ADR-0007).
      try #sql(
        """
        CREATE TABLE "travelProfiles" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "travelPartyID" TEXT NOT NULL REFERENCES "travelParties"("id") ON DELETE CASCADE,
          "plannerID" TEXT,
          "preferences" TEXT NOT NULL DEFAULT ''
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_travelProfiles_on_travelPartyID" ON "travelProfiles"("travelPartyID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Add opening-hours fact columns to ideas (ADR-0016)") { db in
      // Hours are a *fact* on the idea (not an evaluation), with provenance so a
      // HITL-scraped or edited value never reads as authoritative.
      try #sql(#"ALTER TABLE "ideas" ADD COLUMN "openingHours" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "ideas" ADD COLUMN "hoursProvenance" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "ideas" ADD COLUMN "hoursVerifiedAt" TEXT"#).execute(db)
    }
    migrator.registerMigration("Add MapKit identifier to ideas (ADR-0019)") { db in
      // Apple Maps' persistent place identity, the capture dedup key. Plain nullable
      // column, no UNIQUE constraint: dedup is an app-level lookup, and CloudKit can't
      // enforce cross-device uniqueness (a legitimate offline twin must still sync).
      try #sql(#"ALTER TABLE "ideas" ADD COLUMN "mapItemIdentifier" TEXT"#).execute(db)
    }
    migrator.registerMigration("Add description to ideas (ADR-0026)") { db in
      // A page-derived short descriptor (JSON-LD / og:description), split out of `notes`
      // so notes can be the user's own free space (ADR-0026). NOT NULL DEFAULT '' to
      // match the schema's non-optional `description: String` column; existing rows
      // back-fill to empty.
      try #sql(#"ALTER TABLE "ideas" ADD COLUMN "description" TEXT NOT NULL DEFAULT ''"#).execute(db)
    }
    migrator.registerMigration("Add structuredHours to ideas (ADR-0029)") { db in
      // The derived, structured weekday hours behind the WeeklyHours facade — one
      // additive encoded (Codable→JSON string) column, CloudKit-legal. Never queried
      // in SQL; loaded and handed to the pure start-day solver.
      try #sql(#"ALTER TABLE "ideas" ADD COLUMN "structuredHours" TEXT"#).execute(db)
    }
    migrator.registerMigration("Add header-image reference columns to trips (ADR-0032)") { db in
      // The trip "romance" header is a *reference* to an Unsplash photo, not stored
      // bytes — four small additive nullable columns, CloudKit-legal, riding trips'
      // existing share edge. No FK (it's a hotlink, not a relationship), so the
      // single-FK sharing rule (ADR-0007) doesn't apply.
      try #sql(#"ALTER TABLE "trips" ADD COLUMN "headerImageURL" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "trips" ADD COLUMN "headerImageColor" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "trips" ADD COLUMN "headerPhotographerName" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "trips" ADD COLUMN "headerPhotographerUsername" TEXT"#).execute(db)
    }
    migrator.registerMigration("Add dayRank to tripIdeas (ADR-0033)") { db in
      // Manual intra-day order so an untimed ("Anytime") stop can hold a position
      // among timed stops instead of piling at the day's end by pool rank. One
      // additive REAL column, CloudKit-legal. Back-filled from `shortlistRank` —
      // the current intra-day tiebreaker — so existing itineraries keep their order.
      try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "dayRank" REAL NOT NULL DEFAULT 0"#).execute(db)
      try #sql(#"UPDATE "tripIdeas" SET "dayRank" = "shortlistRank""#).execute(db)
    }
    migrator.registerMigration("Add pinned-reservation columns to tripIdeas (docs/trip-time-model.md §4)") { db in
      // A confirmed reservation (OpenTable, a hotel, a timed entry) is an absolute
      // calendar fact, unlike a day-relative planned stop — `pinnedDate` locks it to
      // a real date so it re-derives its `dayNumber` (rather than sliding) when the
      // trip's start date moves. Booking metadata rides alongside it. All additive,
      // nullable columns, CloudKit-legal; `pinnedDate` sits beside `Schedule`, not
      // inside it — the four existing cases are unchanged.
      try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "pinnedDate" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "confirmationNumber" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "bookingURL" TEXT"#).execute(db)
      try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "partySize" INTEGER"#).execute(db)
    }
    migrator.registerMigration("Create calendarReconciliationLedgerEntries table (ADR-0034)") { db in
      // The shared reconciliation outcome rides its trip (one real FK); stopID is
      // a loose UUID so history survives later stop deletion. `id` is a
      // deterministic semantic fingerprint, not a device-generated history UUID:
      // two phones observing one Calendar mutation therefore converge on one row.
      try #sql(
        """
        CREATE TABLE "calendarReconciliationLedgerEntries" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
          "tripID" TEXT NOT NULL REFERENCES "trips"("id") ON DELETE CASCADE,
          "sourceFingerprint" TEXT NOT NULL,
          "stopID" TEXT NOT NULL,
          "eventTitle" TEXT NOT NULL DEFAULT '',
          "currentIsAllDay" INTEGER NOT NULL DEFAULT 0,
          "currentStartDate" TEXT NOT NULL,
          "currentEndDate" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "index_calendarReconciliationLedgerEntries_on_tripID"
        ON "calendarReconciliationLedgerEntries"("tripID")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Add temporal snapshot to calendar reconciliation ledger (ADR-0034)") { db in
      // Slice 3's Date columns cannot represent floating civil times, all-day civil
      // ranges, a presentation zone, or availability without silent loss. Keep them
      // as a legacy projection and add the complete Codable interchange snapshot.
      try #sql(
        #"ALTER TABLE "calendarReconciliationLedgerEntries" ADD COLUMN "currentSnapshot" TEXT"#
      )
      .execute(db)
    }
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
