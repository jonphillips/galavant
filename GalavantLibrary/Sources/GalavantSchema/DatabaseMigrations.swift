import SQLiteData

/// Galavant's append-only migration registry. Keep migration bodies and their registration order stable.
public enum GalavantDatabaseMigrations {
  public static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    GalavantDatabaseMigrationRegistrationsA.register1(into: &migrator)
    GalavantDatabaseMigrationRegistrationsA.register2(into: &migrator)
    GalavantDatabaseMigrationRegistrationsB.register1(into: &migrator)
    GalavantDatabaseMigrationRegistrationsB.register2(into: &migrator)
    return migrator
  }

  public static var schemaVersion: Int { makeMigrator().migrations.count }
}
