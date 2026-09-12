import Foundation

/// A contiguous run of trip days sharing one (optional) region — the unit of the
/// trip *sketch* (ADR-0012). Derived from per-day `TripDayRegion` assignments,
/// never stored: "days 1–4, Loire" is one span over four days, not a shape the
/// model has to hold. A region used on two *non-adjacent* runs stays two spans; two
/// adjacent days with the same region (or both unassigned) are one.
public struct DaySpan: Equatable, Identifiable, Sendable {
  public let startDay: Int
  public let endDay: Int
  public let regionID: MapRegion.ID?

  public init(startDay: Int, endDay: Int, regionID: MapRegion.ID?) {
    self.startDay = startDay
    self.endDay = endDay
    self.regionID = regionID
  }

  /// Stable across edits for `ForEach`: a span is identified by where it begins.
  public var id: Int { startDay }
  /// Inclusive day count — days 1–4 is 4 days.
  public var dayCount: Int { endDay - startDay + 1 }
  public var days: ClosedRange<Int> { startDay...endDay }
  public var isAssigned: Bool { regionID != nil }
}

/// The shape of a trip decided *before any stop exists*: how many days, and which
/// region each day sits in ("four nights Loire, three nights Paris, fly home day
/// 8"). A pure view over `Trip.lengthInDays` + `TripDayRegion` rows (ADR-0012) that
/// the sketch surface edits as contiguous spans and reconciles back to per-day
/// assignments on save. No new table — this is the missing *authoring* surface for a
/// fact ADR-0012 already models (and already pays off: empty-day framing, the
/// region-scoped idea pool).
///
/// The per-day array is the source of truth; spans are always derived, so a "split"
/// only becomes a real boundary once the two sides carry different regions — which
/// is correct, because two adjacent same-region days carry no region information the
/// sketch needs to preserve (a hotel change within one region is the lodging layer's
/// job, not this one's).
public struct TripSketch: Equatable, Sendable {
  /// One entry per day, `dayRegionIDs[0]` == day 1; `nil` == unassigned. The array
  /// count *is* the trip length.
  public private(set) var dayRegionIDs: [MapRegion.ID?]

  /// Build from the persisted facts. Day rows outside `1...lengthInDays` (orphans
  /// left by a since-shortened trip) are dropped; a day with more than one row keeps
  /// the last, matching the single-row-per-day write invariant `setRegion` upholds.
  public init(lengthInDays: Int, dayRegions: [TripDayRegion]) {
    let length = Swift.max(1, lengthInDays)
    var ids = [MapRegion.ID?](repeating: nil, count: length)
    for row in dayRegions where row.dayNumber >= 1 && row.dayNumber <= length {
      ids[row.dayNumber - 1] = row.regionID
    }
    dayRegionIDs = ids
  }

  public var lengthInDays: Int { dayRegionIDs.count }

  /// The contiguous spans, day 1 → N. Adjacent days with the same region id
  /// (including adjacent *unassigned* days) coalesce; a change starts a new span.
  public var spans: [DaySpan] {
    guard lengthInDays >= 1 else { return [] }
    var result: [DaySpan] = []
    var start = 1
    for day in 1...lengthInDays {
      let here = dayRegionIDs[day - 1]
      let endOfRun = day == lengthInDays || dayRegionIDs[day] != here
      if endOfRun {
        result.append(DaySpan(startDay: start, endDay: day, regionID: here))
        start = day + 1
      }
    }
    return result
  }

  /// Assign (or clear, with `nil`) a region across an inclusive day range, clamped to
  /// `1...lengthInDays`. Re-coalescing is a property of `spans`, so there is nothing
  /// to do here but write the days; a sub-range assignment is exactly how one span is
  /// split into two.
  public mutating func assign(_ regionID: MapRegion.ID?, toDays days: ClosedRange<Int>) {
    let lower = Swift.max(1, days.lowerBound)
    let upper = Swift.min(lengthInDays, days.upperBound)
    guard lower <= upper else { return }
    for day in lower...upper {
      dayRegionIDs[day - 1] = regionID
    }
  }

  /// Grow or shrink the trip. New days are unassigned; a shortened trip drops the
  /// tail days (and any region assignment on them) entirely. Clamped to `>= 1`.
  public mutating func setLength(_ newLength: Int) {
    let length = Swift.max(1, newLength)
    if length < dayRegionIDs.count {
      dayRegionIDs.removeLast(dayRegionIDs.count - length)
    } else if length > dayRegionIDs.count {
      dayRegionIDs.append(contentsOf: [MapRegion.ID?](repeating: nil, count: length - dayRegionIDs.count))
    }
  }

  /// The per-day region assignment to persist — day → region, unassigned days
  /// omitted. Feeds `TripDayRegion.replaceAssignments`, which drops every day not
  /// listed (cleared days *and* days past a shortened length).
  public func assignments() -> [Int: MapRegion.ID] {
    var result: [Int: MapRegion.ID] = [:]
    for (index, regionID) in dayRegionIDs.enumerated() {
      if let regionID { result[index + 1] = regionID }
    }
    return result
  }
}
