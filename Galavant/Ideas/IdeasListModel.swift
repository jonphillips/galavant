import CasePaths
import CloudKit
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

@MainActor
@Observable
final class IdeasListModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @Dependency(\.defaultSyncEngine) var syncEngine
  @ObservationIgnored @FetchAll(Idea.order(by: \.name)) var ideas
  var destination: Destination?
  var sharedRecord: SharedRecord?

  @CasePathable
  enum Destination {
    case form(Idea.Draft)
  }

  func shareHouseholdButtonTapped() async {
    await withErrorReporting {
      let household = try await database.write { db in
        try Household.ensure(in: db)
      }
      sharedRecord = try await syncEngine.share(record: household) {
        $0[CKShare.SystemFieldKey.title] = "Galavant Household"
      }
    }
  }

  func addIdeaButtonTapped() {
    destination = .form(Idea.Draft())
  }

  func ideaTapped(_ idea: Idea) {
    destination = .form(Idea.Draft(idea))
  }

  func deleteIdeas(at offsets: IndexSet) {
    let ids = offsets.map { ideas[$0].id }
    withErrorReporting {
      try database.write { db in
        try Idea.where { $0.id.in(ids) }.delete().execute(db)
      }
    }
  }
}
