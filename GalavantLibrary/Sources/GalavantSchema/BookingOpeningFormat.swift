import Foundation

/// The one formatter for a booking opening (ADR-0056 D2), so the To Book sheet, the stop
/// editor and S2's notification text all say the same thing.
public enum BookingOpeningFormat {
  public static func ruleString(
    _ rule: BookingWindowRule, timeZone: TimeZone, locale: Locale = .current
  ) -> String {
    let time: LocalTime?
    let phrase: String
    switch rule {
    case let .daysAhead(days, releaseTime): phrase = "\(days) \(days == 1 ? "day" : "days") ahead"; time = releaseTime
    case let .monthly(day, months, releaseTime): phrase = "day \(day), \(months) \(months == 1 ? "month" : "months") ahead"; time = releaseTime
    case let .fixedDate(value):
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.timeZone = timeZone
      formatter.setLocalizedDateFormatFromTemplate("yMMMd")
      phrase = value.date.date(in: timeZone).map(formatter.string(from:)) ?? value.date.iso8601
      time = value.time
    case .anyTime: return "Any time"
    }
    guard let time else { return phrase }
    var components = DateComponents()
    components.year = 2001; components.month = 1; components.day = 1
    components.hour = time.hour; components.minute = time.minute
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let moment = calendar.date(from: components) ?? .now
    let clock = DateFormatter()
    clock.locale = locale
    clock.timeZone = timeZone
    clock.setLocalizedDateFormatFromTemplate("jmm")
    let zone = timeZone.localizedName(for: .shortGeneric, locale: locale) ?? timeZone.identifier
    return "\(phrase) at \(clock.string(from: moment)) \(zone)"
  }

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
