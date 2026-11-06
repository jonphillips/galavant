import SQLiteData

public struct SeedPlanContext: Sendable {
  public var trip: Trip
  public var tripIdeas: [TripIdea]
  public var ideasByID: [Idea.ID: Idea]
  public var poolIdeas: [Idea]
  public var stays: [TripStay]
  public var tripRegions: [MapRegion]
  public var partyRegions: [MapRegion]

  public init(
    trip: Trip, tripIdeas: [TripIdea], ideasByID: [Idea.ID: Idea], stays: [TripStay],
    tripRegions: [MapRegion], partyRegions: [MapRegion], poolIdeas: [Idea] = []
  ) {
    self.trip = trip
    self.tripIdeas = tripIdeas
    self.ideasByID = ideasByID
    self.poolIdeas = poolIdeas
    self.stays = stays
    self.tripRegions = tripRegions
    self.partyRegions = partyRegions
  }

  public static func load(tripID: Trip.ID, in db: Database) throws -> Self? {
    guard let trip = try Trip.find(tripID).fetchOne(db) else { return nil }
    let ideas = try Idea.order(by: \.name).fetchAll(db)
    let regions = try MapRegion.order(by: \.name).fetchAll(db)
    let tripRegionIDs = Set(try TripRegion.where { $0.tripID.eq(tripID) }.fetchAll(db).map(\.regionID))
    return Self(
      trip: trip,
      tripIdeas: try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db),
      ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }),
      stays: try TripStay.where { $0.tripID.eq(tripID) }.fetchAll(db),
      tripRegions: regions.filter { tripRegionIDs.contains($0.id) },
      partyRegions: regions.filter { $0.travelPartyID == trip.travelPartyID },
      poolIdeas: ideas
    )
  }
}
