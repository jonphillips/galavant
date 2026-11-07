import Foundation

/// The unfiltered observations that feed one trip's plan. Keep the raw published
/// buffers here: equality can short-circuit when a fetch republishes the same buffer.
public struct TripPlanInputs: Equatable, Sendable {
  public var tripID: Trip.ID
  public var lengthInDays: Int
  public var tripIdeas: [TripIdea]
  public var ideas: [Idea]
  public var tripStays: [TripStay]
  public var dayRegions: [TripDayRegion]
  public var regions: [MapRegion]
  public var calendarConstraints: [CalendarTripConstraint]
  public var alternativeGroups: [TripAlternativeGroup]

  public init(
    tripID: Trip.ID, lengthInDays: Int, tripIdeas: [TripIdea], ideas: [Idea],
    tripStays: [TripStay], dayRegions: [TripDayRegion], regions: [MapRegion],
    calendarConstraints: [CalendarTripConstraint], alternativeGroups: [TripAlternativeGroup]
  ) {
    self.tripID = tripID
    self.lengthInDays = lengthInDays
    self.tripIdeas = tripIdeas
    self.ideas = ideas
    self.tripStays = tripStays
    self.dayRegions = dayRegions
    self.regions = regions
    self.calendarConstraints = calendarConstraints
    self.alternativeGroups = alternativeGroups
  }
}

extension TripPlan {
  /// Build with the same trip scoping and first-row lookup semantics as the
  /// planning model's former getter.
  public init(_ inputs: TripPlanInputs) {
    self.init(
      entries: inputs.tripIdeas.filter { $0.tripID == inputs.tripID },
      ideasByID: Dictionary(inputs.ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: inputs.lengthInDays,
      tripStays: inputs.tripStays.filter { $0.tripID == inputs.tripID },
      dayRegions: inputs.dayRegions.filter { $0.tripID == inputs.tripID },
      regionsByID: Dictionary(inputs.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      calendarConstraints: inputs.calendarConstraints.filter { $0.tripID == inputs.tripID },
      alternativeGroups: inputs.alternativeGroups.filter { $0.tripID == inputs.tripID })
  }
}

/// Observation-safe, value-semantic cache for a trip plan. Every call receives
/// every input so Swift Observation keeps tracking all fetches on cache hits.
public struct TripPlanSnapshot: Sendable {
  public private(set) var buildCount = 0
  private var inputs: TripPlanInputs?
  private var cachedPlan: TripPlan?

  public init() {}

  public mutating func plan(for inputs: TripPlanInputs) -> TripPlan {
    if let current = self.inputs, current == inputs {
      // Adopt republished equal buffers so later hits regain Array's identity fast path.
      self.inputs = inputs
      return cachedPlan!
    }
    self.inputs = inputs
    let plan = TripPlan(inputs)
    cachedPlan = plan
    buildCount += 1
    return plan
  }
}
