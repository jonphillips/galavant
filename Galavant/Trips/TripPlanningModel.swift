import CasePaths
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns one trip's planning surface (ADR-0004): the shortlist + considering
/// pile of pulled ideas, and the filtered pool you pull *from*. Persistence
/// delegates to the tested `TripIdea` operations; pool scoping reuses the pure
/// `poolFiltered`. The view stays presentation.
@MainActor
@Observable
final class TripPlanningModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @FetchAll(Idea.order(by: \.name)) var ideas
  @ObservationIgnored @FetchAll(TripIdea.all) var allTripIdeas
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var regions
  @ObservationIgnored @FetchAll(Tag.order(by: \.name)) var tags
  @ObservationIgnored @FetchAll(IdeaTag.all) var ideaTags

  let tripID: Trip.ID
  var mode: Mode = .shortlist
  var destination: Destination?

  // Pool lens (reused from the Ideas screen, M2c).
  var selectedRegionID: MapRegion.ID?
  var selectedKinds: Set<IdeaKind> = []
  var selectedTagIDs: Set<Tag.ID> = []
  var includeVisited = true

  enum Mode: String, CaseIterable, Identifiable {
    case shortlist, add
    var id: Self { self }
    var label: String { self == .shortlist ? "Shortlist" : "Add" }
  }

  @CasePathable
  enum Destination {
    case edit(Trip.Draft)
  }

  init(tripID: Trip.ID) {
    self.tripID = tripID
  }

  // MARK: - Derived state

  var trip: Trip? { trips.first { $0.id == tripID } }

  private var entries: [TripIdea] { allTripIdeas.filter { $0.tripID == tripID } }
  private var ideaByID: [Idea.ID: Idea] {
    Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Shortlisted-onward entries in rank order, paired with their idea (orphans
  /// whose idea was deleted from the pool are dropped — ADR-0007 read-time
  /// reconciliation).
  var shortlist: [Resolved] {
    TripIdea.shortlist(entries).compactMap(resolve)
  }

  var considering: [Resolved] {
    TripIdea.considering(entries).compactMap(resolve)
  }

  private func resolve(_ entry: TripIdea) -> Resolved? {
    ideaByID[entry.ideaID].map { Resolved(entry: entry, idea: $0) }
  }

  /// A pulled entry joined to its idea, for the planning rows.
  struct Resolved: Identifiable {
    var entry: TripIdea
    var idea: Idea
    var id: TripIdea.ID { entry.id }
  }

  // MARK: - Add mode (the pool, scoped by the lens)

  var ideaTagIDs: [Idea.ID: Set<Tag.ID>] {
    Dictionary(grouping: ideaTags, by: \.ideaID).mapValues { Set($0.map(\.tagID)) }
  }
  var selectedRegion: MapRegion? { regions.first { $0.id == selectedRegionID } }

  var filteredPool: [Idea] {
    poolFiltered(
      ideas,
      region: selectedRegion,
      kinds: selectedKinds,
      includeVisited: includeVisited,
      tagIDs: selectedTagIDs,
      ideaTagIDs: ideaTagIDs
    )
  }

  private var statusByIdea: [Idea.ID: TripIdeaStatus] {
    Dictionary(entries.map { ($0.ideaID, $0.status) }, uniquingKeysWith: { first, _ in first })
  }

  /// This idea's status on the trip, or nil if it hasn't been pulled.
  func status(for idea: Idea) -> TripIdeaStatus? { statusByIdea[idea.id] }

  var sortedRegions: [MapRegion] {
    regions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
  var sortedTags: [Tag] {
    tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
  var isFiltering: Bool {
    selectedRegionID != nil || !selectedKinds.isEmpty || !selectedTagIDs.isEmpty || !includeVisited
  }

  func toggleKind(_ kind: IdeaKind) {
    if selectedKinds.contains(kind) { selectedKinds.remove(kind) } else { selectedKinds.insert(kind) }
  }
  func toggleTag(_ id: Tag.ID) {
    if selectedTagIDs.contains(id) { selectedTagIDs.remove(id) } else { selectedTagIDs.insert(id) }
  }
  func clearFilters() {
    selectedRegionID = nil
    selectedKinds = []
    selectedTagIDs = []
    includeVisited = true
  }

  // MARK: - Actions

  func editButtonTapped() {
    guard let trip else { return }
    destination = .edit(Trip.Draft(trip))
  }

  /// Pull an idea onto the trip as a "considering" maybe (the default + action).
  func pull(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
      }
    }
  }

  /// Pull straight onto the ranked shortlist (one transaction).
  func pullToShortlist(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  func setStatus(_ status: TripIdeaStatus, for idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.setStatus(status, ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  func remove(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.remove(ideaID: ideaID, from: tripID, in: db)
      }
    }
  }

  func deleteShortlist(at offsets: IndexSet) {
    deletePulled(offsets.map { shortlist[$0].idea.id })
  }

  func deleteConsidering(at offsets: IndexSet) {
    deletePulled(offsets.map { considering[$0].idea.id })
  }

  private func deletePulled(_ ideaIDs: [Idea.ID]) {
    let tripID = tripID
    withErrorReporting {
      try database.write { db in
        for ideaID in ideaIDs { try TripIdea.remove(ideaID: ideaID, from: tripID, in: db) }
      }
    }
  }

  /// Persist a new shortlist order after a drag-to-reorder.
  func reorderShortlist(_ orderedEntryIDs: [TripIdea.ID]) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.reorderShortlist(orderedEntryIDs, in: db)
      }
    }
  }
}
