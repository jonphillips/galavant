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

  static func register2(into migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Add trip rationale fields (ADR-0055)") { db in
      try #sql("ALTER TABLE tripIdeas ADD COLUMN rationaleVisit TEXT").execute(db)
      try #sql("ALTER TABLE tripIdeas ADD COLUMN rationaleWhy TEXT").execute(db)
      try #sql("ALTER TABLE tripIdeas ADD COLUMN rationaleFit TEXT").execute(db)
    }
  }

  static func register3(into migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Add trip rationale priority fields (ADR-0055 D7)") { db in
      try #sql("ALTER TABLE tripIdeas ADD COLUMN rationalePriority INTEGER").execute(db)
      try #sql("ALTER TABLE tripIdeas ADD COLUMN rationalePriorityOutOf INTEGER").execute(db)
    }
  }

  static func register4(into migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Add ranked list name to trip rationale (ADR-0055 D10)") { db in
      try #sql("ALTER TABLE tripIdeas ADD COLUMN rationalePriorityList TEXT").execute(db)
    }
  }
}
