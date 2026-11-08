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
  var category: GuideCategory = .dining
  var shelf: GuideShelf = .all
  private var initialScopeApplied = false
  private var initialPreferredTripID: Trip.ID?
  var chosenTripID: Trip.ID?
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
    $lastRegionID.withLock { $0 = region?.id.uuidString ?? "" }
  }

  func tripSelected(_ tripID: Trip.ID) {
    chosenTripID = tripID
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
    return result != nil
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

  func distanceFromStay(entry: TripIdea, day: Int) -> String? {
    guard let trip = trips.first(where: { $0.id == entry.tripID }) else { return nil }
    let inputs = TripPlanInputs(
      tripID: trip.id, lengthInDays: trip.lengthInDays, tripIdeas: tripIdeas, ideas: ideas,
      tripStays: tripStays, dayRegions: tripDayRegions, regions: regions,
      calendarConstraints: calendarConstraints, alternativeGroups: alternativeGroups)
    let plan = planSnapshot.plan(for: inputs)
    guard let stayID = plan.stayID(owningDay: day),
      let stay = tripStays.first(where: { $0.id == stayID }),
      let hotelID = stay.ideaID,
      let hotel = ideas.first(where: { $0.id == hotelID }),
      let latitude = hotel.latitude, let longitude = hotel.longitude,
      let ideaID = entry.ideaID,
      let idea = ideas.first(where: { $0.id == ideaID }),
      let placeLatitude = idea.latitude, let placeLongitude = idea.longitude
    else { return nil }
    let distance = GuideTripLens.distanceInKilometers(
      from: TripCoordinate(latitude: placeLatitude, longitude: placeLongitude),
      to: TripCoordinate(latitude: latitude, longitude: longitude))
    return "\(distance.formatted(.number.precision(.fractionLength(1)))) km from \(hotel.name)"
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
