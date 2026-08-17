import Foundation

/// Assignment-zone precedence is intentionally independent from the romance
/// region concept: explicit day override, then day region, then trip centroid.
public enum CalendarTripTimeZoneResolver {
  public static func resolve(
    dayOverride: TimeZone?, dayRegion: TimeZone?, tripCentroid: TimeZone?
  ) -> TimeZone? {
    dayOverride ?? dayRegion ?? tripCentroid
  }

  public static func resolve(
    day: DayNumber,
    overrides: [DayNumber: TimeZone],
    dayRegions: [DayNumber: TimeZone],
    tripCentroid: TimeZone?
  ) -> TimeZone? {
    resolve(
      dayOverride: overrides[day], dayRegion: dayRegions[day], tripCentroid: tripCentroid)
  }
}
