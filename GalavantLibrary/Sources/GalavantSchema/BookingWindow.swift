import Foundation

public struct LocalDate: Codable, Equatable, Hashable, Sendable {
  public var year: Int
  public var month: Int
  public var day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  private enum CodingKeys: String, CodingKey { case year, month, day }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let year = try values.decode(Int.self, forKey: .year)
    let month = try values.decode(Int.self, forKey: .month)
    let day = try values.decode(Int.self, forKey: .day)
    guard let utc = TimeZone(secondsFromGMT: 0),
      LocalDate(year: year, month: month, day: day).date(in: utc) != nil
    else { throw DecodingError.dataCorruptedError(forKey: .day, in: values, debugDescription: "Invalid civil date") }
    self.init(year: year, month: month, day: day)
  }

  public init?(iso8601: String) {
    let parts = iso8601.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    self.init(year: parts[0], month: parts[1], day: parts[2])
    guard let utc = TimeZone(secondsFromGMT: 0), date(in: utc) != nil else { return nil }
  }

  public init(date: Date, in timeZone: TimeZone) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    year = calendar.component(.year, from: date)
    month = calendar.component(.month, from: date)
    day = calendar.component(.day, from: date)
  }

  public func date(in timeZone: TimeZone) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    guard let value = calendar.date(from: components),
      calendar.component(.year, from: value) == year,
      calendar.component(.month, from: value) == month,
      calendar.component(.day, from: value) == day
    else { return nil }
    return value
  }

  public var iso8601: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

public struct LocalTime: Codable, Equatable, Hashable, Sendable {
  public var hour: Int
  public var minute: Int

  public init?(hour: Int, minute: Int) {
    guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
    self.hour = hour
    self.minute = minute
  }

  private enum CodingKeys: String, CodingKey { case hour, minute }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let hour = try values.decode(Int.self, forKey: .hour)
    let minute = try values.decode(Int.self, forKey: .minute)
    guard let value = LocalTime(hour: hour, minute: minute) else {
      throw DecodingError.dataCorruptedError(forKey: .hour, in: values, debugDescription: "Invalid local time")
    }
    self = value
  }

  public init?(iso8601: String) {
    let parts = iso8601.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, let value = LocalTime(hour: parts[0], minute: parts[1]) else { return nil }
    self = value
  }

  public var iso8601: String { String(format: "%02d:%02d", hour, minute) }
}

public struct LocalDateTime: Codable, Equatable, Hashable, Sendable {
  public var date: LocalDate
  public var time: LocalTime

  public init(date: LocalDate, time: LocalTime) {
    self.date = date
    self.time = time
  }
}

public enum BookingWindowRule: Codable, Equatable, Sendable {
  case daysAhead(Int, releaseTime: LocalTime?)
  case monthly(dayOfMonth: Int, monthsAhead: Int, releaseTime: LocalTime?)
  case fixedDate(LocalDateTime)
  case anyTime

  private enum CodingKeys: String, CodingKey { case kind, days, dayOfMonth, monthsAhead, releaseTime, date }
  private enum Kind: String, Codable { case daysAhead, monthly, fixedDate, anyTime }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .daysAhead: self = .daysAhead(try values.decode(Int.self, forKey: .days), releaseTime: try values.decodeIfPresent(LocalTime.self, forKey: .releaseTime))
    case .monthly: self = .monthly(dayOfMonth: try values.decode(Int.self, forKey: .dayOfMonth), monthsAhead: try values.decode(Int.self, forKey: .monthsAhead), releaseTime: try values.decodeIfPresent(LocalTime.self, forKey: .releaseTime))
    case .fixedDate: self = .fixedDate(try values.decode(LocalDateTime.self, forKey: .date))
    case .anyTime: self = .anyTime
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .daysAhead(days, time):
      try values.encode(Kind.daysAhead, forKey: .kind); try values.encode(days, forKey: .days); try values.encodeIfPresent(time, forKey: .releaseTime)
    case let .monthly(day, months, time):
      try values.encode(Kind.monthly, forKey: .kind); try values.encode(day, forKey: .dayOfMonth); try values.encode(months, forKey: .monthsAhead); try values.encodeIfPresent(time, forKey: .releaseTime)
    case let .fixedDate(value): try values.encode(Kind.fixedDate, forKey: .kind); try values.encode(value, forKey: .date)
    case .anyTime: try values.encode(Kind.anyTime, forKey: .kind)
    }
  }

  public func opening(forMealOn mealDate: LocalDate, mealTime: LocalTime?, in timeZone: TimeZone, now: Date) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let targetDate: LocalDate
    let targetTime: LocalTime
    switch self {
    case let .daysAhead(days, releaseTime):
      guard days >= 0 else { return nil }
      guard let date = mealDate.date(in: timeZone), let adjusted = calendar.date(byAdding: .day, value: -days, to: date) else { return nil }
      targetDate = LocalDate(year: calendar.component(.year, from: adjusted), month: calendar.component(.month, from: adjusted), day: calendar.component(.day, from: adjusted))
      targetTime = releaseTime ?? LocalTime(hour: 0, minute: 0)!
    case let .monthly(day, months, releaseTime):
      guard (1...31).contains(day), months >= 0, let date = mealDate.date(in: timeZone),
        let month = calendar.date(byAdding: .month, value: -months, to: date),
        let range = calendar.range(of: .day, in: .month, for: month), range.contains(day)
      else { return nil }
      targetDate = LocalDate(year: calendar.component(.year, from: month), month: calendar.component(.month, from: month), day: day)
      targetTime = releaseTime ?? LocalTime(hour: 0, minute: 0)!
    case let .fixedDate(value): targetDate = value.date; targetTime = value.time
    case .anyTime: return now
    }
    guard let day = targetDate.date(in: timeZone) else { return nil }
    var components = calendar.dateComponents([.year, .month, .day], from: day)
    components.hour = targetTime.hour
    components.minute = targetTime.minute
    components.second = 0
    return calendar.date(from: components)
  }
}

public enum BookingWindowSource: String, Codable, Equatable, Sendable { case chat, scout }

public struct BookingWindow: Codable, Equatable, Sendable {
  public var rule: BookingWindowRule
  public var timeZoneID: String?
  public var sourceURL: String
  public var quote: String
  public var source: BookingWindowSource
  public var foundAt: Date

  public init(rule: BookingWindowRule, timeZoneID: String?, sourceURL: String, quote: String, source: BookingWindowSource = .chat, foundAt: Date) {
    self.rule = rule; self.timeZoneID = timeZoneID; self.sourceURL = sourceURL; self.quote = quote; self.source = source; self.foundAt = foundAt
  }

  public static func decode(_ encoded: String?) -> BookingWindow? {
    guard let encoded, let data = encoded.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }

  public func encoded() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func fromHandoff(_ object: [String: Any], now: Date) -> BookingWindow? {
    guard let kind = object["kind"] as? String,
      let sourceURL = object["source_url"] as? String,
      let quote = object["quote"] as? String,
      let url = URL(string: sourceURL), url.scheme != nil
    else { return nil }
    let time = (object["release_time"] as? String).flatMap(LocalTime.init(iso8601:))
    let rule: BookingWindowRule
    switch kind {
    case "days_ahead":
      guard let days = object["days"] as? Int, days >= 0 else { return nil }
      if object["release_time"] != nil && time == nil { return nil }
      rule = .daysAhead(days, releaseTime: time)
    case "monthly":
      guard let day = object["day_of_month"] as? Int, let months = object["months_ahead"] as? Int,
        (1...31).contains(day), months >= 0 else { return nil }
      if object["release_time"] != nil && time == nil { return nil }
      rule = .monthly(dayOfMonth: day, monthsAhead: months, releaseTime: time)
    case "fixed_date":
      guard let dateText = object["date"] as? String, let date = LocalDate(iso8601: dateText),
        let time else { return nil }
      rule = .fixedDate(LocalDateTime(date: date, time: time))
    case "any_time": rule = .anyTime
    default: return nil
    }
    return BookingWindow(rule: rule, timeZoneID: object["time_zone"] as? String, sourceURL: sourceURL, quote: quote, foundAt: now)
  }
}

public struct BookingWindowHandoff: Codable, Equatable, Sendable {
  public var kind: String
  public var days: Int?
  public var dayOfMonth: Int?
  public var monthsAhead: Int?
  public var date: String?
  public var releaseTime: String?
  public var timeZone: String?
  public var sourceURL: String
  public var quote: String

  enum CodingKeys: String, CodingKey {
    case kind, days, date, quote
    case dayOfMonth = "day_of_month"
    case monthsAhead = "months_ahead"
    case releaseTime = "release_time"
    case timeZone = "time_zone"
    case sourceURL = "source_url"
  }

  public init(from window: BookingWindow) {
    switch window.rule {
    case let .daysAhead(days, time):
      kind = "days_ahead"; self.days = days; dayOfMonth = nil; monthsAhead = nil; date = nil; releaseTime = time?.iso8601
    case let .monthly(day, months, time):
      kind = "monthly"; days = nil; dayOfMonth = day; monthsAhead = months; date = nil; releaseTime = time?.iso8601
    case let .fixedDate(value):
      kind = "fixed_date"; days = nil; dayOfMonth = nil; monthsAhead = nil; date = value.date.iso8601; releaseTime = value.time.iso8601
    case .anyTime:
      kind = "any_time"; days = nil; dayOfMonth = nil; monthsAhead = nil; date = nil; releaseTime = nil
    }
    timeZone = window.timeZoneID
    sourceURL = window.sourceURL
    quote = window.quote
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    kind = try values.decode(String.self, forKey: .kind)
    days = try values.decodeIfPresent(Int.self, forKey: .days)
    dayOfMonth = try values.decodeIfPresent(Int.self, forKey: .dayOfMonth)
    monthsAhead = try values.decodeIfPresent(Int.self, forKey: .monthsAhead)
    date = try values.decodeIfPresent(String.self, forKey: .date)
    releaseTime = try values.decodeIfPresent(String.self, forKey: .releaseTime)
    timeZone = try values.decodeIfPresent(String.self, forKey: .timeZone)
    sourceURL = try values.decode(String.self, forKey: .sourceURL)
    quote = try values.decode(String.self, forKey: .quote)
  }

  public func bookingWindow(foundAt: Date) -> BookingWindow? {
    var object: [String: Any] = ["kind": kind, "source_url": sourceURL, "quote": quote]
    if let days { object["days"] = days }
    if let dayOfMonth { object["day_of_month"] = dayOfMonth }
    if let monthsAhead { object["months_ahead"] = monthsAhead }
    if let date { object["date"] = date }
    if let releaseTime { object["release_time"] = releaseTime }
    if let timeZone { object["time_zone"] = timeZone }
    return BookingWindow.fromHandoff(object, now: foundAt)
  }
}

public struct BookingSuggestion: Equatable, Sendable {
  public var opensAt: Date?
  public var rule: BookingWindowRule

  public static func make(
    status: BookingStatus?, kind: IdeaKind?, hasOpeningDate: Bool, mealDate: LocalDate?, mealTime: LocalTime?,
    dayTimeZone: TimeZone, window: BookingWindow?, now: Date
  ) -> BookingSuggestion? {
    guard status == .toBook, kind == .food, !hasOpeningDate, let window else { return nil }
    let zone = window.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? dayTimeZone
    let opening = mealDate.flatMap { window.rule.opening(forMealOn: $0, mealTime: mealTime, in: zone, now: now) }
    return BookingSuggestion(opensAt: opening, rule: window.rule)
  }
}
