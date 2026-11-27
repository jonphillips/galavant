import Foundation

/// The one formatter for a booking opening (ADR-0056 D2), so the To Book sheet, the stop
/// editor, and S2's notification text all say the same thing.
enum BookingOpeningFormat {
  static func string(
    moment: Date, timeZone: TimeZone, deviceTimeZone: TimeZone, locale: Locale = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
    let date = formatter.string(from: moment)
    guard let label = zoneLabel(moment: moment, timeZone: timeZone, deviceTimeZone: deviceTimeZone)
    else { return date }
    return "\(date) \(label)"
  }

  /// The zone's abbreviation at `moment` (so daylight saving matches the date shown), or
  /// nil when the zone is the device's own.
  static func zoneLabel(moment: Date, timeZone: TimeZone, deviceTimeZone: TimeZone) -> String? {
    guard timeZone.identifier != deviceTimeZone.identifier else { return nil }
    return timeZone.abbreviation(for: moment)
  }
}
