import Foundation

/// The one formatter for a booking opening (ADR-0056 D2), so the To Book sheet, the stop
/// editor and S2's notification text all say the same thing.
public enum BookingOpeningFormat {
  public static func string(
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

  public static func mealDate(_ date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
    return formatter.string(from: date)
  }

  public static func timeString(
    moment: Date, timeZone: TimeZone, deviceTimeZone: TimeZone, locale: Locale = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    let time = formatter.string(from: moment)
    guard let label = zoneLabel(moment: moment, timeZone: timeZone, deviceTimeZone: deviceTimeZone)
    else { return time }
    return "\(time) \(label)"
  }

  public static func zoneLabel(moment: Date, timeZone: TimeZone, deviceTimeZone: TimeZone) -> String? {
    guard timeZone.identifier != deviceTimeZone.identifier else { return nil }
    return timeZone.abbreviation(for: moment)
  }
}
