import Dependencies
import GalavantSchema
import Observation
import SQLiteData

@MainActor
@Observable
final class TagManagementSettingsModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @FetchAll(Tag.all) var tags
  @ObservationIgnored @FetchAll(IdeaTag.all) var ideaTags

  var index: TagIndex { TagIndex(tags: tags, ideaTags: ideaTags) }

  func convergeDuplicates() {
    withErrorReporting {
      try database.write { db in _ = try Tag.convergeDuplicates(in: db) }
    }
  }

  func rename(_ tag: Tag, to name: String) {
    withErrorReporting {
      try database.write { db in _ = try Tag.rename(tag.id, to: name, in: db) }
    }
  }

  func delete(_ tag: Tag) {
    withErrorReporting {
      try database.write { db in try Tag.delete([tag.id], in: db) }
    }
  }

  func deleteUnused() {
    withErrorReporting {
      try database.write { db in _ = try Tag.deleteUnused(in: db) }
    }
  }
}
