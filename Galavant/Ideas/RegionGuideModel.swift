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
  @ObservationIgnored @FetchAll(Idea.all) var ideas
  @ObservationIgnored @FetchAll(IdeaEvaluation.all) var evaluations
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(MapRegion.all) var regions
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @FetchAll(TripIdea.all) var tripIdeas
  @ObservationIgnored @FetchAll(TripStay.all) var tripStays
  @ObservationIgnored @FetchAll(TripDayRegion.all) var tripDayRegions
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
    didSet { focusedSlot = nil }
  }
  var shelf: GuideShelf = .all
  private var initialScopeApplied = false
  private var initialPreferredTripID: Trip.ID?
  var chosenTripID: Trip.ID?
  var focusedSlot: GuideSlotFocus?
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

  var visibleGuide: RegionGuide? {
    guard let guide, let focusedSlot, case .open = focusedSlot.content else { return guide }
    return guide.filtered(to: Set(focusedSlot.ideaIDs))
  }

  var mapGuide: RegionGuide? {
    guard let guide, let focusedSlot else { return guide }
    return guide.filtered(to: Set(focusedSlot.ideaIDs))
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
    return GuideTripLens(trip: trip, candidates: choices, region: region, category: category, plan: plan, calendar: calendar)
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
    focusedSlot = nil
    $lastRegionID.withLock { $0 = region?.id.uuidString ?? "" }
  }

  func tripSelected(_ tripID: Trip.ID) {
    chosenTripID = tripID
    focusedSlot = nil
  }

  func slotTapped(day: Int, meal: Meal) {
    if focusedSlot?.day == day, focusedSlot?.meal == meal {
      focusedSlot = nil
      return
    }
    rebuildFocusedSlot(day: day, meal: meal)
  }

  func clearSlotFocus() {
    focusedSlot = nil
  }

  func refreshFocusedSlot() {
    guard let focusedSlot else { return }
    rebuildFocusedSlot(day: focusedSlot.day, meal: focusedSlot.meal)
  }

  private func rebuildFocusedSlot(day: Int, meal: Meal) {
    guard let lens = tripLens else { focusedSlot = nil; return }
    let candidateIdeaIDs = Set(guide?.sections.flatMap(\.cards).map(\.idea.id) ?? [])
    focusedSlot = GuideSlotFocus(day: day, meal: meal, lens: lens,
      entries: tripIdeas.filter { $0.tripID == lens.trip.id }, ideas: ideas,
      candidateIdeaIDs: candidateIdeaIDs)
  }

  func lensFoldButtonTapped() {
    $lensFolded.withLock { $0.toggle() }
  }

  func tripStopTapped(_ ideaID: Idea.ID?) {
    guard let ideaID else { return }
    destination = .dossier(ideaID)
  }

  func slotMenu(for ideaID: Idea.ID) -> GuideSlotMenu? {
    guard let lens = tripLens, let idea = ideas.first(where: { $0.id == ideaID }) else { return nil }
    let entries = tripIdeas.filter { $0.tripID == lens.trip.id }
    let stays = tripStays.filter { $0.tripID == lens.trip.id }
    return GuideSlotMenu(lens: lens, idea: idea, entries: entries, stays: stays, calendar: calendar)
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
    refreshFocusedSlot()
    return true
  }

  func setActive(stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in _ = try TripIdea.setActiveAlternative(stopID: stopID, in: db) }
    }
    refreshFocusedSlot()
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
    refreshFocusedSlot()
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
}
