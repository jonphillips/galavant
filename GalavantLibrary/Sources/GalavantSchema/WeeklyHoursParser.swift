import Foundation

/// Turns the schema.org-shaped opening-hours tokens the capture parser already mines
/// (`ParsedPage.openingHours`) into a `WeeklyHours` — the deterministic, model-free
/// first rung of the structuring ladder (ADR-0029 §3.1). Handles the machine format
/// (`"Mo-Fr 10:00-18:00"`), day lists (`"Mo,We,Fr 09:00-13:00"`), the
/// `openingHoursSpecification`-derived lines our JSON-LD extractor emits (full day
/// names, one range per line), split service across multiple lines for the same day
/// (→ two `ServicePeriod`s), and an explicit `"closed"`.
///
/// Meals arrive `nil` — derived on read; intervals are the schema.org clock. Days no
/// line mentions stay `.unknown` (**never** silently `.closed`, ADR-0029 §1). Returns
/// `nil` when nothing parses, so the caller can fall through to the LLM rung.
public enum WeeklyHoursParser {
  public static func parse(_ tokens: [String]) -> WeeklyHours? {
    var days = Array(repeating: DayHours.unknown, count: 7)
    var touched = false

    for token in tokens {
      let (weekdays, closed, intervals) = parseLine(token)
      guard !weekdays.isEmpty else { continue }
      for weekday in weekdays {
        let index = weekday.rawValue
        if closed {
          days[index] = .closed
          touched = true
        } else if !intervals.isEmpty {
          var periods: [ServicePeriod]
          if case let .open(existing) = days[index] { periods = existing } else { periods = [] }
          periods.append(contentsOf: intervals.map { ServicePeriod(interval: $0) })
          days[index] = .open(periods)
          touched = true
        } else {
          // Day named without a time ("Mo-Su"): open, no service detail — but don't
          // clobber intervals a prior line already established for this day.
          if case .open = days[index] {} else {
            days[index] = .open([])
            touched = true
          }
        }
      }
    }

    return touched ? WeeklyHours(days: days) : nil
  }

  /// Parse one line into its days, an explicit-closed flag, and any clock intervals.
  private static func parseLine(_ line: String) -> (
    weekdays: [Weekday], closed: Bool, intervals: [OpenInterval]
  ) {
    let lower = line.lowercased()
    let closed = lower.contains("closed")
    let intervals = closed ? [] : clockIntervals(in: line)
    // The day spec is whatever precedes the first digit (the times) — keeps
    // "Mo-Fr 10:00-18:00" and "Monday,Tuesday 09:00-17:00" both clean.
    let daySpec = String(line.prefix { !$0.isNumber })
    return (weekdays(in: daySpec), closed, intervals)
  }

  /// Expand a day spec — comma/space separated tokens and `Xx-Yy` ranges — into
  /// concrete weekdays, order-preserving and de-duplicated.
  private static func weekdays(in spec: String) -> [Weekday] {
    var result: [Weekday] = []
    func append(_ weekday: Weekday) { if !result.contains(weekday) { result.append(weekday) } }

    let pieces = spec.split { $0 == "," || $0 == " " || $0 == "\t" || $0 == "/" }
    for piece in pieces {
      let range = piece.split(separator: "-", maxSplits: 1)
      if range.count == 2, let lower = weekday(String(range[0])), let upper = weekday(String(range[1])) {
        var current = lower
        append(current)
        while current != upper {
          current = current.adding(days: 1)
          append(current)
        }
      } else if let single = weekday(String(piece)) {
        append(single)
      }
    }
    return result
  }

  /// A single day token — schema.org abbreviation (`Mo`) or full name (`Monday`),
  /// case-insensitive. Two letters disambiguate every weekday (Tu/Th, Sa/Su).
  private static func weekday(_ token: String) -> Weekday? {
    let key = token.trimmingCharacters(in: .whitespaces).lowercased().prefix(2)
    switch key {
    case "mo": return .monday
    case "tu": return .tuesday
    case "we": return .wednesday
    case "th": return .thursday
    case "fr": return .friday
    case "sa": return .saturday
    case "su": return .sunday
    default: return nil
    }
  }

  /// Every `H:mm-H:mm` clock range in a line (a line may carry two for split
  /// service). A range whose close is at or before its open is read as running past
  /// midnight (`+24h`), so `22:00-02:00` becomes `1320–1560`.
  private static func clockIntervals(in line: String) -> [OpenInterval] {
    var intervals: [OpenInterval] = []
    let scanner = Scanner(string: line)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \t,")
    while !scanner.isAtEnd {
      guard let open = scanClock(scanner) else {
        // Advance past a non-time character and keep scanning.
        if scanner.currentIndex < line.endIndex {
          scanner.currentIndex = line.index(after: scanner.currentIndex)
        }
        continue
      }
      _ = scanner.scanCharacters(from: CharacterSet(charactersIn: "-–— \t"))
      guard let close = scanClock(scanner) else { continue }
      intervals.append(OpenInterval(open: open, close: close <= open ? close + 24 * 60 : close))
    }
    return intervals
  }

  /// Scan an `H:mm` / `HH:mm` clock at the scanner's position → minutes of day, or
  /// `nil` (rewinding) when the next tokens aren't a clock.
  private static func scanClock(_ scanner: Scanner) -> Int? {
    let restore = scanner.currentIndex
    guard let hour = scanner.scanInt(), scanner.scanString(":") != nil,
      let minuteString = scanner.scanCharacters(from: .decimalDigits), minuteString.count == 2,
      let minute = Int(minuteString), (0...29).contains(hour), (0..<60).contains(minute)
    else {
      scanner.currentIndex = restore
      return nil
    }
    return hour * 60 + minute
  }
}
