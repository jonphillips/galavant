import Foundation

enum BookingOpeningFormat {
  static func string(moment: Date, timeZone: TimeZone, deviceTimeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d, h:mm a"
    let date = formatter.string(from: moment)
    guard timeZone.identifier != deviceTimeZone.identifier,
      let abbreviation = timeZone.abbreviation(for: moment)
    else { return date }
    return "\(date) \(abbreviation)"
  }
}
