import CasePaths
import Dependencies
import Foundation
import GalavantPlaces
import GalavantSchema
import SQLiteData
import Sharing
import SwiftUI

@MainActor
@Observable
final class RegionGuideModel {
  private struct FocusedSlotKey: Equatable {
    var day: Int
    var meal: Meal
  }

  @ObservationIgnored @FetchAll(Idea.all) var ideas
  @ObservationIgnored @FetchAll(IdeaEvaluation.all) var evaluations
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(MapRegion.all) var regions
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @FetchAll(TripIdea.all) var tripIdeas
  @ObservationIgnored @FetchAll(TripStay.all) var tripStays
  @ObservationIgnored @FetchAll(TripDayRegion.all) var tripDayRegions
  @ObservationIgnored @FetchAll(TripDayNote.all) var tripDayNotes
  @ObservationIgnored @FetchAll(CalendarTripConstraint.all) var calendarConstraints
  @ObservationIgnored @FetchAll(TripAlternativeGroup.all) var alternativeGroups
  @ObservationIgnored @FetchAll(TasteNote.where { $0.ideaID.isNot(nil) }) var notes
  @ObservationIgnored @FetchAll(ImageAsset.where { $0.isHeader.eq(true) }
    .select { HeaderThumb.Columns(ideaID: $0.ideaID, thumbnail: $0.thumbnail) }) var headerThumbs
  @ObservationIgnored @Shared(.appStorage("lastRegionGuideID")) private var lastRegionID = ""
  @ObservationIgnored @Shared(.appStorage("regionGuideLensFolded")) var lensFolded = false
  @ObservationIgnored @Dependency(\.date) var date
  @ObservationIgnored @Dependency(\.calendar) var calendar
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored private var planSnapshot = TripPlanSnapshot()

  var region: MapRegion?
  var category: GuideCategory = .dining {
    didSet {
      focusedSlotKey = nil
      selectedListName = nil
    }
  }
  var shelf: GuideShelf = .all
  private var initialScopeApplied = false
  private var initialPreferredTripID: Trip.ID?
  var chosenTripID: Trip.ID?
  var selectedListName: String?
  private var focusedSlotKey: FocusedSlotKey?
  var successfulAddCount = 0
  var destination: Destination?

  @CasePathable
  enum Destination {
    case dossier(Idea.ID)
    case form(IdeasListModel.IdeaFormPresentation)
  }

  @Selection
  struct HeaderThumb {
    let ideaID: Idea.ID
    let thumbnail: Data
  }

  var guide: RegionGuide? {
    guard let region else { return nil }
    return RegionGuide(
      region: region, category: category, shelf: shelf, ideas: ideas,
      evaluations: evaluations, interests: interests, planners: planners, notes: notes
    )
  }

  var focusedSlot: GuideSlotFocus? {
    guard let lens = tripLens else { return nil }
    return focusedSlot(in: lens, guide: guide)
  }

  func focusedSlot(in lens: GuideTripLens, guide: RegionGuide?) -> GuideSlotFocus? {
    guard let key = focusedSlotKey else { return nil }
    let candidateIdeaIDs = Set(guide?.sections.flatMap(\.cards).map(\.idea.id) ?? [])
    return GuideSlotFocus(day: key.day, meal: key.meal, lens: lens,
      entries: tripIdeas.filter { $0.tripID == lens.trip.id }, ideas: ideas,
      candidateIdeaIDs: candidateIdeaIDs)
  }

  func visibleGuide(_ guide: RegionGuide?, focusedSlot: GuideSlotFocus?) -> RegionGuide? {
    guard let guide else { return nil }
    var ideaIDs = Set(guide.sections.flatMap(\.cards).map(\.idea.id))
    if let focusedSlot, case .open = focusedSlot.content { ideaIDs.formIntersection(focusedSlot.ideaIDs) }
    guard let selectedList else {
      guard let focusedSlot, case .open = focusedSlot.content else { return guide }
      return guide.filtered(to: ideaIDs)
    }
    return guide.ordered(as: selectedList.members.map(\.ideaID).filter(ideaIDs.contains), title: selectedList.name)
  }

  func mapGuide(_ guide: RegionGuide?, focusedSlot: GuideSlotFocus?) -> RegionGuide? {
    guard let guide else { return nil }
    var ideaIDs = Set(guide.sections.flatMap(\.cards).map(\.idea.id))
    if let focusedSlot { ideaIDs.formIntersection(focusedSlot.ideaIDs) }
    guard let selectedList else {
      return focusedSlot == nil ? guide : guide.filtered(to: ideaIDs)
    }
    return guide.ordered(as: selectedList.members.map(\.ideaID).filter(ideaIDs.contains), title: selectedList.name)
  }

  func availableLists(for lens: GuideTripLens, guide: RegionGuide?) -> [TripIdea.RankedList] {
    guard guide != nil, let region else { return [] }
    let allGuide = RegionGuide(
      region: region, category: category, shelf: .all, ideas: ideas,
      evaluations: evaluations, interests: interests, planners: planners, notes: notes)
    let guideIDs = Set(allGuide.sections.flatMap(\.cards).map(\.idea.id))
    return TripIdea.rankedLists(entries: tripIdeas.filter { $0.tripID == lens.trip.id })
      .compactMap { list in
        let members = list.members.filter { guideIDs.contains($0.ideaID) }
        guard !members.isEmpty else { return nil }
        return TripIdea.RankedList(name: list.name, members: members)
      }
  }

  var selectedList: TripIdea.RankedList? {
    guard let selectedListName, let tripLens else { return nil }
    return availableLists(for: tripLens, guide: guide).first { $0.name == selectedListName }
  }

  var selectedListRanks: [Idea.ID: TripIdea.RankedList.Member] {
    Dictionary(selectedList?.members.map { ($0.ideaID, $0) } ?? [], uniquingKeysWith: { first, _ in first })
  }

  var tripLens: GuideTripLens? {
    guard let region else { return nil }
    let choices = GuideTripLens.candidates(
      region: region, trips: trips, dayRegions: tripDayRegions, now: date(), calendar: calendar)
    guard !choices.isEmpty else { return nil }
    let selectedID = GuideTripLens.chosenTripID(
      chipPick: chosenTripID, preferred: initialPreferredTripID, candidates: choices)
    guard let selectedID,
          let trip = trips.first(where: { $0.id == selectedID }) else { return nil }
    let inputs = TripPlanInputs(
      tripID: trip.id, lengthInDays: trip.lengthInDays, tripIdeas: tripIdeas, ideas: ideas,
      tripStays: tripStays, dayRegions: tripDayRegions, regions: regions,
      calendarConstraints: calendarConstraints, alternativeGroups: alternativeGroups)
    let plan = planSnapshot.plan(for: inputs)
    return GuideTripLens(
      trip: trip, candidates: choices, region: region, category: category,
      plan: plan, dayNotes: tripDayNotes, calendar: calendar)
  }

  func openChoiceRanks(for lens: GuideTripLens) -> [Idea.ID: ChatRank] {
    TripIdea.openChoiceRanks(entries: tripIdeas.filter { $0.tripID == lens.trip.id })
  }

  var headerThumbnailByIdea: [Idea.ID: Data] {
    Dictionary(headerThumbs.map { ($0.ideaID, $0.thumbnail) }, uniquingKeysWith: { first, _ in first })
  }

  var sortedRegions: [MapRegion] {
    regions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var dossierID: Idea.ID? {
    guard case let .dossier(ideaID) = destination else { return nil }
    return ideaID
  }

  func tripRationale(for ideaID: Idea.ID?, tripLens: GuideTripLens?) -> TripRationale? {
    guard let ideaID, let tripID = tripLens?.trip.id else { return nil }
    let stops = tripIdeas.filter { $0.tripID == tripID && $0.ideaID == ideaID }
    let ordered = TripIdea.canonicalAlternativeOrder(stops)
    let scheduled = ordered.first { $0.status == .scheduled }
    let active = TripIdea.effectiveActiveEntries(stops)
      .sorted { ($0.shortlistRank, $0.id.uuidString) < ($1.shortlistRank, $1.id.uuidString) }
      .first
    let selected = scheduled ?? active ?? ordered.first
    return selected?.rationale
  }

  func task(scope: RegionGuideScope) {
    guard !initialScopeApplied else { return }
    initialScopeApplied = true
    category = scope.category
    initialPreferredTripID = scope.preferredTripID
    selectRegion(scope.region)
  }

  func selectRegion(_ region: MapRegion?) {
    self.region = region
    chosenTripID = nil
    selectedListName = nil
    focusedSlotKey = nil
    $lastRegionID.withLock { $0 = region?.id.uuidString ?? "" }
  }

  func tripSelected(_ tripID: Trip.ID) {
    chosenTripID = tripID
    selectedListName = nil
    focusedSlotKey = nil
  }

  func slotTapped(day: Int, meal: Meal) {
    if focusedSlotKey == FocusedSlotKey(day: day, meal: meal) {
      focusedSlotKey = nil
      return
    }
    focusedSlotKey = FocusedSlotKey(day: day, meal: meal)
  }

  func clearSlotFocus() {
    focusedSlotKey = nil
  }

  func lensFoldButtonTapped() {
    $lensFolded.withLock { $0.toggle() }
  }

  func tripStopTapped(_ ideaID: Idea.ID?) {
    guard let ideaID else { return }
    destination = .dossier(ideaID)
  }

  func slotMenu(for ideaID: Idea.ID) -> GuideSlotMenu? {
    guard let lens = tripLens else { return nil }
    return slotMenu(for: ideaID, lens: lens)
  }

  func slotMenu(for ideaID: Idea.ID, lens: GuideTripLens) -> GuideSlotMenu? {
    guard let idea = ideas.first(where: { $0.id == ideaID }) else { return nil }
    let entries = tripIdeas.filter { $0.tripID == lens.trip.id }
    let stays = tripStays.filter { $0.tripID == lens.trip.id }
    return GuideSlotMenu(lens: lens, idea: idea, entries: entries, stays: stays, calendar: calendar)
  }

  func slotRows(
    for ideas: [Idea], focusedSlot: GuideSlotFocus?, lens: GuideTripLens?
  ) -> [Idea.ID: GuideSlotMenu.Row] {
    guard let focusedSlot, case .open = focusedSlot.content, let lens else { return [:] }
    let entries = tripIdeas.filter { $0.tripID == lens.trip.id }
    let stays = tripStays.filter { $0.tripID == lens.trip.id }
    return Dictionary(uniqueKeysWithValues: ideas.compactMap { idea in
      GuideSlotMenu(lens: lens, idea: idea, entries: entries, stays: stays, calendar: calendar)
        .row(day: focusedSlot.day, meal: focusedSlot.meal)
        .map { (idea.id, $0) }
    })
  }

  @discardableResult
  func addToTrip(_ action: GuideSlotAction, ideaID: Idea.ID) -> Bool {
    guard let tripID = tripLens?.trip.id else { return false }
    let result: Void? = withErrorReporting {
      try database.write { db in
        try action.apply(ideaID: ideaID, tripID: tripID, in: db)
      }
    }
    guard result != nil else { return false }
    successfulAddCount += 1
    return true
  }

  func setActive(stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in _ = try TripIdea.setActiveAlternative(stopID: stopID, in: db) }
    }
  }

  func takeOut(stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        if let entry = try TripIdea.find(stopID).fetchOne(db), entry.alternativeGroupID != nil {
          try TripIdea.detachAlternative(stopID: stopID, in: db)
        } else {
          try TripIdea.unschedule(stopID: stopID, in: db)
        }
      }
    }
  }

  func distanceFromStay(ideaID: Idea.ID?, tripID: Trip.ID, day: Int) -> (distance: Measurement<UnitLength>, hotelName: String)? {
    guard let ideaID, let trip = trips.first(where: { $0.id == tripID }) else { return nil }
    let inputs = TripPlanInputs(
      tripID: trip.id, lengthInDays: trip.lengthInDays, tripIdeas: tripIdeas, ideas: ideas,
      tripStays: tripStays, dayRegions: tripDayRegions, regions: regions,
      calendarConstraints: calendarConstraints, alternativeGroups: alternativeGroups)
    let plan = planSnapshot.plan(for: inputs)
    return GuideTripLens.distanceFromStay(
      day: day, ideaID: ideaID, plan: plan, stays: tripStays, ideas: ideas)
  }

  func ideaTapped(_ idea: Idea) {
    destination = .dossier(idea.id)
  }

  func closeDossier() {
    if case .dossier = destination { destination = nil }
  }

  func mapPlaceTapped(_ place: Place) async {
    let draft = await MapPlaceCapture().draft(for: place)
    destination = .form(IdeasListModel.IdeaFormPresentation(
      draft: draft, searchRegions: region.map { [$0] } ?? []))
  }
}

private extension RegionGuide {
  func filtered(to ideaIDs: Set<Idea.ID>) -> RegionGuide {
    let sections = self.sections.compactMap { section -> RegionGuide.Section? in
      let cards = section.cards.filter { ideaIDs.contains($0.idea.id) }
      guard !cards.isEmpty else { return nil }
      return RegionGuide.Section(title: section.title, cards: cards, id: section.id)
    }
    return RegionGuide(sections: sections, counts: counts)
  }

  func ordered(as ideaIDs: [Idea.ID], title: String) -> RegionGuide {
    let cardsByID = Dictionary(
      sections.flatMap(\.cards).map { ($0.idea.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let cards = ideaIDs.compactMap { cardsByID[$0] }
    return RegionGuide(
      sections: cards.isEmpty ? [] : [RegionGuide.Section(title: title, cards: cards, id: "list")],
      counts: counts
    )
  }
}
