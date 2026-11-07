import SQLiteData

/// Migrations appended after the B registry outgrew SwiftLint's type-size limit.
enum GalavantDatabaseMigrationRegistrationsC {
  static func register1(into migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create tasteNotes table (ADR-0053)") { db in
      try #sql(
        """
        CREATE TABLE "tasteNotes" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "travelPartyID" TEXT NOT NULL REFERENCES "travelParties"("id") ON DELETE CASCADE,
          "plannerID" TEXT,
          "ideaID" TEXT,
          "placeName" TEXT,
          "body" TEXT NOT NULL,
          "source" TEXT NOT NULL DEFAULT 'planner',
          "sourceDetail" TEXT,
          "notedAt" TEXT NOT NULL
        ) STRICT
        """
      ).execute(db)
      try #sql(
        #"CREATE INDEX "index_tasteNotes_on_travelPartyID" ON "tasteNotes"("travelPartyID")"#
      ).execute(db)
      try #sql(
        #"CREATE INDEX "index_tasteNotes_on_ideaID" ON "tasteNotes"("ideaID")"#
      ).execute(db)
    }
  }
}
