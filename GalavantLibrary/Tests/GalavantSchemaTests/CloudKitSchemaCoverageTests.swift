import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

/// `testflight`'s schema gate compares Development with Production, so it passes when
/// both lack a field. `cloudkit-expected-fields.txt` closes that gap: `testflight` fails
/// unless Production has every field it lists. This suite makes the list follow the code,
/// so a synced column can't ship without its CloudKit fields being checked.
@Suite(.dependencies { try $0.bootstrapDatabase() })
struct CloudKitSchemaCoverageTests {
  @Dependency(\.defaultDatabase) var database

  @Test func expectedFieldsListCoversEverySyncedColumn() throws {
    let listed = try Self.expectedFields()
    let synced = Set(Self.syncedFields())

    let missing = synced.subtracting(listed).sorted()
    #expect(
      missing.isEmpty,
      """
      cloudkit-expected-fields.txt is missing \(missing.count) synced field(s). Add them to \
      the CloudKit schema with `cktool import-schema` (jon-platform \
      docs/ios/persistence-and-sync.md § Adding a synced table or column), deploy to \
      Production, then list them:
      \(missing.joined(separator: "\n"))
      """
    )

    let stale = listed.subtracting(synced).sorted()
    #expect(
      stale.isEmpty,
      """
      cloudkit-expected-fields.txt lists \(stale.count) field(s) no synced table writes. \
      Remove them, or fix the record type or column name:
      \(stale.joined(separator: "\n"))
      """
    )
  }

  @Test func recordSchemasMatchTheEngineTables() {
    let schemaTypes = GalavantCloudSync.syncedRecordSchemas.map(\.recordType)
    #expect(schemaTypes == GalavantCloudSync.syncedTables.recordTypes)
    #expect(Set(schemaTypes).count == 26)
  }

  /// `Data` columns sync as an asset plus `<column>_hash`. Asset detection reads the Swift
  /// type, so hold it against the columns the migrations actually declare as BLOB.
  @Test func assetColumnsAreExactlyTheBlobColumns() async throws {
    let schemas = GalavantCloudSync.syncedRecordSchemas
    let blobColumns = try await database.read { db in
      try schemas.flatMap { schema in
        try String.fetchAll(
          db,
          sql: "SELECT name FROM pragma_table_info(?) WHERE upper(type) = 'BLOB'",
          arguments: [schema.recordType]
        ).map { "\(schema.recordType).\($0)" }
      }
    }
    let assetColumns = schemas.flatMap { schema in
      schema.columns.filter(\.isAsset).map { "\(schema.recordType).\($0.name)" }
    }
    #expect(Set(assetColumns) == Set(blobColumns))
    #expect(
      Set(assetColumns) == [
        "imageAssets.display", "imageAssets.thumbnail",
        "regionImages.display", "regionImages.thumbnail",
      ]
    )
  }

  @Test func dataColumnsExpectAnAssetHashAndModificationTime() throws {
    let imageAssets = try #require(
      GalavantCloudSync.syncedRecordSchemas.first { $0.recordType == "imageAssets" }
    )
    let fields = Set(imageAssets.cloudKitFields)
    #expect(fields.isSuperset(of: [
      "display", "display_hash", "sqlitedata_icloud_userModificationTime_display",
    ]))
    #expect(!fields.contains("id_hash"))
  }

  static func syncedFields() -> [String] {
    GalavantCloudSync.syncedRecordSchemas.flatMap { schema in
      schema.cloudKitFields.map { "\(schema.recordType) \($0)" }
    }
  }

  /// The list at the repository root, in `testflight`'s `<recordType> <field>` format.
  static func expectedFields() throws -> Set<String> {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()  // GalavantSchemaTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // GalavantLibrary
      .deletingLastPathComponent()  // repository root
    let text = try String(
      contentsOf: root.appending(path: "cloudkit-expected-fields.txt"), encoding: .utf8
    )
    return Set(
      text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )
  }
}
