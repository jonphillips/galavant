import Foundation

public struct GalavantChatExport: Codable, Equatable, Sendable {
  public struct Trip: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var startDate: Date?
    public var targetYear: Int?
    public var targetQuarter: Int?
    public var lengthInDays: Int
    public var notes: String
    public var planLines: [String]
    public var ruledOutLines: [String]
    public var tasteLines: [String]
    public var consideringTitles: [String]
    public var shortlistedTitles: [String]

    public init(id: UUID, name: String, startDate: Date?, targetYear: Int? = nil, targetQuarter: Int? = nil,
                lengthInDays: Int, notes: String,
                planLines: [String], ruledOutLines: [String], tasteLines: [String],
                consideringTitles: [String], shortlistedTitles: [String]) {
      self.id = id
      self.name = name
      self.startDate = startDate
      self.targetYear = targetYear
      self.targetQuarter = targetQuarter
      self.lengthInDays = lengthInDays
      self.notes = notes
      self.planLines = planLines
      self.ruledOutLines = ruledOutLines
      self.tasteLines = tasteLines
      self.consideringTitles = consideringTitles
      self.shortlistedTitles = shortlistedTitles
    }

    private enum CodingKeys: String, CodingKey {
      case id, name, startDate, targetYear, targetQuarter, lengthInDays, notes
      case planLines, ruledOutLines, tasteLines, consideringTitles, shortlistedTitles
    }

    public func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(id, forKey: .id)
      try values.encode(name, forKey: .name)
      try values.encode(startDate, forKey: .startDate)
      try values.encode(targetYear, forKey: .targetYear)
      try values.encode(targetQuarter, forKey: .targetQuarter)
      try values.encode(lengthInDays, forKey: .lengthInDays)
      try values.encode(notes, forKey: .notes)
      try values.encode(planLines, forKey: .planLines)
      try values.encode(ruledOutLines, forKey: .ruledOutLines)
      try values.encode(tasteLines, forKey: .tasteLines)
      try values.encode(consideringTitles, forKey: .consideringTitles)
      try values.encode(shortlistedTitles, forKey: .shortlistedTitles)
    }
  }

  public var version: Int
  public var generatedAt: Date
  public var device: String
  public var trips: [Trip]

  public init(version: Int = 1, generatedAt: Date, device: String, trips: [Trip]) {
    self.version = version
    self.generatedAt = generatedAt
    self.device = device
    self.trips = trips
  }

  public enum DecodeError: Error, Equatable { case unsupportedVersion(Int) }

  public static func decode(_ data: Data) throws -> Self {
    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
       let version = object["version"] as? Int, version != 1 {
      throw DecodeError.unsupportedVersion(version)
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == 1 else { throw DecodeError.unsupportedVersion(value.version) }
    return value
  }
}

public enum GalavantChatExportBuilder {
  public static func build(
    trips: [Trip], entries: [TripIdea], ideas: [Idea], stays: [TripStay],
    dayRegions: [TripDayRegion], regions: [MapRegion], constraints: [CalendarTripConstraint],
    alternativeGroups: [TripAlternativeGroup], profiles: [TravelProfile], planners: [Planner],
    generatedAt: Date, device: String, checkCancellation: () throws -> Void = {}
  ) throws -> GalavantChatExport {
    let ideasByID = Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let regionsByID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let entriesByTrip = Dictionary(grouping: entries, by: \.tripID)
    let staysByTrip = Dictionary(grouping: stays, by: \.tripID)
    let dayRegionsByTrip = Dictionary(grouping: dayRegions, by: \.tripID)
    let constraintsByTrip = Dictionary(grouping: constraints, by: \.tripID)
    let alternativesByTrip = Dictionary(grouping: alternativeGroups, by: \.tripID)
    let tasteByParty = TravelProfile.promptLinesByParty(
      Set(trips.compactMap(\.travelPartyID)), profiles: profiles, planners: planners)

    var exportedTrips: [GalavantChatExport.Trip] = []
    for trip in trips {
      try checkCancellation()
      let plan = TripPlan(
        entries: entriesByTrip[trip.id] ?? [], ideasByID: ideasByID,
        lengthInDays: trip.lengthInDays, tripStays: staysByTrip[trip.id] ?? [],
        dayRegions: dayRegionsByTrip[trip.id] ?? [], regionsByID: regionsByID,
        calendarConstraints: constraintsByTrip[trip.id] ?? [],
        alternativeGroups: alternativesByTrip[trip.id] ?? []
      )
      let partyID = trip.travelPartyID
      let taste = partyID.flatMap { tasteByParty[$0] } ?? []
      exportedTrips.append(GalavantChatExport.Trip(
        id: trip.id, name: trip.name, startDate: trip.startDate, targetYear: trip.targetYear,
        targetQuarter: trip.targetQuarter?.rawValue, lengthInDays: trip.lengthInDays,
        notes: trip.notes, planLines: RecommendationHandoffContract.stopSummary(plan: plan),
        ruledOutLines: RecommendationHandoffContract.ruledOutSummary(plan: plan), tasteLines: taste,
        consideringTitles: plan.considering.map { $0.content.title },
        shortlistedTitles: plan.shortlist.map { $0.content.title }
      ))
    }
    return GalavantChatExport(generatedAt: generatedAt, device: device, trips: exportedTrips)
  }
}
