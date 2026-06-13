import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns a trip being created/edited. The certainty pipeline is edited as
/// separate fields (stage + the columns each stage needs) and folded back into
/// a `Certainty` on save; persistence delegates to the tested package
/// operations (`Trip.create` / `Trip.update`).
@MainActor
@Observable
final class TripFormModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database

  var draft: Trip.Draft
  var stage: CertaintyStage
  var targetYear: Int
  var targetQuarter: Quarter?
  var startDate: Date
  var lengthInDays: Int

  init(draft: Trip.Draft) {
    @Dependency(\.date.now) var now
    let thisYear = Calendar.current.component(.year, from: now)
    self.draft = draft
    self.stage = draft.certaintyStage
    self.targetYear = draft.targetYear ?? thisYear
    self.targetQuarter = draft.targetQuarter
    self.startDate = draft.startDate ?? now
    self.lengthInDays = max(1, draft.lengthInDays)
  }

  var isNew: Bool { draft.id == nil }
  var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

  /// Five sensible years to target from, starting at the current one.
  var selectableYears: [Int] { Array(targetYear...(targetYear + 5)) }

  /// The chosen stage folded back into the domain value.
  var certainty: Certainty {
    switch stage {
    case .someday: .someday(rank: draft.somedayRank)
    case .targeted: .targeted(year: targetYear, quarter: targetQuarter)
    case .dated: .dated(start: startDate)
    }
  }

  func saveButtonTapped() {
    let lengthInDays = lengthInDays
    let certainty = certainty
    var draft = draft
    draft.lengthInDays = lengthInDays
    withErrorReporting {
      try database.write { db in
        if draft.id == nil {
          _ = try Trip.create(
            name: draft.name,
            certainty: certainty,
            lengthInDays: lengthInDays,
            notes: draft.notes,
            in: db
          )
        } else {
          try Trip.update(draft, certainty: certainty, in: db)
        }
      }
    }
  }
}
