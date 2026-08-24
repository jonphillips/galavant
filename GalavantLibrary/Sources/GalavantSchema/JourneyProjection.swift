import Foundation

/// The read-only, coarse whole-trip projection used by the iPad Journey
/// surface. It is intentionally derived from `TripPlan` rather than persisted:
/// the planning itinerary remains the source of truth.
public struct JourneyProjection: Equatable, Sendable {
  public struct StopDigest: Identifiable, Equatable, Sendable {
    public var id: TripIdea.ID
    /// The underlying idea, when this stop resolves to one — the key the day
    /// disclosure uses to look up the stop's header image (`ImageAsset.ideaID`).
    public var ideaID: Idea.ID?
    public var title: String
    public var kind: IdeaKind?

    public init(id: TripIdea.ID, ideaID: Idea.ID?, title: String, kind: IdeaKind?) {
      self.id = id
      self.ideaID = ideaID
      self.title = title
      self.kind = kind
    }
  }

  public struct DaySummary: Identifiable, Equatable, Sendable {
    public var dayNumber: Int
    public var date: Date
    public var locality: String?
    public var stops: [StopDigest]
    public var definingStop: StopDigest?
    public var weatherAnchors: [WeatherAnchor]
    public var transferFrom: TravelEndpoint?
    public var transferTo: TravelEndpoint?
    public var transferMode: TransportMode?
    public var transferTime: TravelTime?
    /// The lodging handoff Journey should surface, even when an intermediate
    /// stop suppresses the itinerary's direct connector row.
    public var lodgingChangeover: TravelConnector?

    public var id: Int { dayNumber }
    public var stopTitles: [String] { stops.map(\.title) }
    public var stopCount: Int { stops.count }
    public var isTransfer: Bool { transferFrom != nil && transferTo != nil }
    public var hasLodgingChangeover: Bool { lodgingChangeover != nil }

    public init(
      dayNumber: Int,
      date: Date,
      locality: String?,
      stops: [StopDigest],
      definingStop: StopDigest?,
      weatherAnchors: [WeatherAnchor],
      transferFrom: TravelEndpoint? = nil,
      transferTo: TravelEndpoint? = nil,
      transferMode: TransportMode? = nil,
      transferTime: TravelTime? = nil,
      lodgingChangeover: TravelConnector? = nil
    ) {
      self.dayNumber = dayNumber
      self.date = date
      self.locality = locality
      self.stops = stops
      self.definingStop = definingStop
      self.weatherAnchors = weatherAnchors
      self.transferFrom = transferFrom
      self.transferTo = transferTo
      self.transferMode = transferMode
      self.transferTime = transferTime
      self.lodgingChangeover = lodgingChangeover
    }
  }

  public struct StayBand: Identifiable, Equatable, Sendable {
    public var stay: ResolvedStay
    public var nights: Range<Int>
    public var title: String

    public var id: TripStay.ID { stay.id }
    public var nightCount: Int { nights.count }
    public var regionName: String? { stay.idea?.regionName }

    public init(stay: ResolvedStay, nights: Range<Int>, title: String) {
      self.stay = stay
      self.nights = nights
      self.title = title
    }
  }

  public struct TripSummary: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var dayCount: Int
    public var regionNames: [String]
    public var stayCount: Int
    public var transferDayCount: Int

    /// Nights slept equals days minus one — the framing hotels and travellers
    /// use ("15 nights"), which reads more naturally than a raw day count.
    public var nightCount: Int { max(0, dayCount - 1) }

    public init(
      startDate: Date,
      endDate: Date,
      dayCount: Int,
      regionNames: [String],
      stayCount: Int,
      transferDayCount: Int = 0
    ) {
      self.startDate = startDate
      self.endDate = endDate
      self.dayCount = dayCount
      self.regionNames = regionNames
      self.stayCount = stayCount
      self.transferDayCount = transferDayCount
    }
  }

  public var days: [DaySummary]
  public var stayBands: [StayBand]
  public var summary: TripSummary

  public init(days: [DaySummary], stayBands: [StayBand], summary: TripSummary) {
    self.days = days
    self.stayBands = stayBands
    self.summary = summary
  }

  public static func resolve(
    from tripPlan: TripPlan,
    tripStartDate: Date,
    travelTimes: [LegKey: [TransportMode: TravelTime]] = [:]
  ) -> Self {
    let calendar = Calendar.current
    let dayNumbers = tripPlan.lengthInDays > 0 ? Array(1...tripPlan.lengthInDays) : []
    let days = dayNumbers.compactMap { dayNumber -> DaySummary? in
      guard let date = calendar.date(
        byAdding: .day, value: dayNumber - 1, to: tripStartDate)
      else { return nil }

      let stops = tripPlan.itinerary.first { $0.number == dayNumber }?.stops ?? []
      let digests = stops.map {
        StopDigest(id: $0.id, ideaID: $0.idea?.id, title: $0.content.title, kind: $0.idea?.kind)
      }
      let definingStop = digests.first(where: { isWeatherSensitive($0.kind) }) ?? digests.first
      let transfer = tripPlan.transferConnector(forDay: dayNumber, travelTimes: travelTimes)
      let lodgingChangeover = tripPlan.lodgingChangeoverConnector(
        forDay: dayNumber, travelTimes: travelTimes)

      return DaySummary(
        dayNumber: dayNumber,
        date: date,
        locality: locality(for: dayNumber, in: tripPlan, stops: stops),
        stops: digests,
        definingStop: definingStop,
        weatherAnchors: WeatherAnchor.resolve(
          forDay: dayNumber,
          in: tripPlan,
          tripStartDate: tripStartDate,
          travelTimes: travelTimes),
        transferFrom: transfer?.from,
        transferTo: transfer?.to,
        transferMode: transfer?.mode,
        transferTime: transfer?.travelTime,
        lodgingChangeover: lodgingChangeover)
    }

    let stayBands = tripPlan.stays.compactMap { stay -> StayBand? in
      guard !stay.stay.nights.isEmpty else { return nil }
      return StayBand(stay: stay, nights: stay.stay.nights, title: stay.content.title)
    }
    let regionNames = days.reduce(into: [String]()) { names, day in
      guard let locality = day.locality, !names.contains(locality) else { return }
      names.append(locality)
    }
    let endDate = calendar.date(
      byAdding: .day,
      value: max(0, tripPlan.lengthInDays - 1),
      to: tripStartDate) ?? tripStartDate
    // The header count intentionally includes every lodging handoff. The day
    // summary's `isTransfer` remains the narrower pure-transfer presentation fact.
    let transferDayCount = lodgingTransferDayCount(in: tripPlan)
    return Self(
      days: days,
      stayBands: stayBands,
      summary: TripSummary(
        startDate: tripStartDate,
        endDate: endDate,
        dayCount: days.count,
        regionNames: regionNames,
        stayCount: stayBands.count,
        transferDayCount: transferDayCount))
  }

  private static func locality(
    for dayNumber: Int,
    in tripPlan: TripPlan,
    stops: [ResolvedStop]
  ) -> String? {
    let stays = tripPlan.stays(coveringDay: dayNumber)
    return tripPlan.region(forDay: dayNumber)?.name
      ?? stays.first { $0.stay.nights.contains(dayNumber) }?.idea?.regionName
      ?? stays.compactMap { $0.idea?.regionName }.first
      ?? stops.compactMap { $0.idea?.regionName }.first
  }

  private static func isWeatherSensitive(_ kind: IdeaKind?) -> Bool {
    switch kind {
    case .outdoorTrail, .beach, .park, .activity:
      true
    default:
      false
    }
  }

  private static func lodgingTransferDayCount(in tripPlan: TripPlan) -> Int {
    Set(
      tripPlan.stays.compactMap { leaving -> Int? in
        let day = leaving.stay.checkOutDay
        let anotherArrives = tripPlan.stays.contains {
          $0.id != leaving.id && $0.stay.checkInDay == day
        }
        return anotherArrives ? day : nil
      }
    ).count
  }
}
