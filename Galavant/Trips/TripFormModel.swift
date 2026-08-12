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
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var allRegions

  var draft: Trip.Draft
  var stage: CertaintyStage
  var targetYear: Int
  var targetQuarter: Quarter?
  var startDate: Date
  var lengthInDays: Int
  /// The regions this trip spans — the persistent planning lens (M3b.1).
  var selectedRegionIDs: Set<MapRegion.ID> = []
  private var didLoadRegions = false

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

  var sortedRegions: [MapRegion] {
    allRegions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Comma-joined names of the selected regions, for the form's summary row.
  var selectedRegionsSummary: String {
    let names = sortedRegions.filter { selectedRegionIDs.contains($0.id) }.map(\.name)
    return names.isEmpty ? "None" : names.joined(separator: ", ")
  }

  /// Load the editing trip's existing regions into the multi-select — once.
  /// (`.task` re-runs when the form reappears after the region-picker subscreen
  /// pops; without this guard it would reload from the DB and discard the user's
  /// in-picker toggles.)
  func task() async {
    guard !didLoadRegions, let id = draft.id else { return }
    didLoadRegions = true
    await withErrorReporting {
      let ids = try await database.read { db in
        try TripRegion.regionIDs(forTrip: id, in: db)
      }
      selectedRegionIDs = Set(ids)
    }
  }

  func toggleRegion(_ id: MapRegion.ID) {
    if selectedRegionIDs.contains(id) {
      selectedRegionIDs.remove(id)
    } else {
      selectedRegionIDs.insert(id)
    }
  }

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
    let regionIDs = selectedRegionIDs
    var draft = draft
    draft.lengthInDays = lengthInDays
    withErrorReporting {
      try database.write { db in
        let tripID: Trip.ID
        if let id = draft.id {
          try Trip.update(draft, certainty: certainty, in: db)
          tripID = id
        } else {
          tripID = try Trip.create(
            name: draft.name,
            certainty: certainty,
            lengthInDays: lengthInDays,
            notes: draft.notes,
            mainTransportMode: draft.mainTransportMode.flatMap(TransportMode.init(rawValue:)),
            in: db
          ).id
        }
        try TripRegion.setRegions(regionIDs, forTrip: tripID, in: db)
      }
    }
  }
}
