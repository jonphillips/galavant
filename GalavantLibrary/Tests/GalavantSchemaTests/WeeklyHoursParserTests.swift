import GalavantSchema
import Testing

@Suite struct WeeklyHoursParserTests {
  @Test("Machine-format day range with a clock interval")
  func rangeWithInterval() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Mo-Fr 10:00-18:00"]))
    for weekday in [Weekday.monday, .tuesday, .wednesday, .thursday, .friday] {
      #expect(hours[weekday] == .open([ServicePeriod(interval: OpenInterval(open: 600, close: 1080))]))
    }
    // Days no line mentions stay unknown — never silently closed (ADR-0029 §1).
    #expect(hours[.saturday] == .unknown)
    #expect(hours[.sunday] == .unknown)
  }

  @Test("Comma-separated day list")
  func dayList() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Mo,We,Fr 09:00-13:00"]))
    #expect(hours[.monday].serves(.lunch) == true)
    #expect(hours[.wednesday].serves(.lunch) == true)
    #expect(hours[.friday].serves(.lunch) == true)
    #expect(hours[.tuesday] == .unknown)
  }

  @Test("Full day names (openingHoursSpecification lines) parse")
  func fullDayNames() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Monday,Tuesday 09:00-17:00"]))
    #expect(hours[.monday] == .open([ServicePeriod(interval: OpenInterval(open: 540, close: 1020))]))
    #expect(hours[.tuesday] == .open([ServicePeriod(interval: OpenInterval(open: 540, close: 1020))]))
  }

  @Test("Split service across two lines for the same day becomes two periods")
  func splitAcrossLines() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Tu 12:00-14:00", "Tu 19:00-22:00"]))
    #expect(
      hours[.tuesday]
        == .open([
          ServicePeriod(interval: OpenInterval(open: 720, close: 840)),
          ServicePeriod(interval: OpenInterval(open: 1140, close: 1320)),
        ])
    )
    #expect(hours[.tuesday].serves(.lunch) == true)
    #expect(hours[.tuesday].serves(.dinner) == true)
  }

  @Test("Two clock ranges on one line become two periods")
  func twoRangesOneLine() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Sa 12:00-14:00,19:00-22:00"]))
    #expect(hours[.saturday].serves(.lunch) == true)
    #expect(hours[.saturday].serves(.dinner) == true)
  }

  @Test("An explicit closed day is closed, not unknown")
  func explicitClosed() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Mo 10:00-18:00", "Tu Closed"]))
    #expect(hours[.tuesday] == .closed)
    #expect(hours[.monday].serves(.lunch) == true)
  }

  @Test("A day named without a time is open with no detail")
  func dayWithoutTime() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Mo-Su"]))
    #expect(hours[.monday] == .open([]))
    #expect(hours[.monday].serves(.dinner) == nil)  // open, asserts nothing on the meal
    #expect(!hours[.monday].isClosed)
  }

  @Test("Past-midnight close rolls over 24h")
  func pastMidnight() throws {
    let hours = try #require(WeeklyHoursParser.parse(["Fr 22:00-02:00"]))
    #expect(hours[.friday] == .open([ServicePeriod(interval: OpenInterval(open: 1320, close: 1560))]))
  }

  @Test("Input with no recognizable day tokens yields nil")
  func nothingParses() {
    // The parser's contract is schema.org-shaped tokens; a token with no weekday
    // code/name simply doesn't register.
    #expect(WeeklyHoursParser.parse([]) == nil)
    #expect(WeeklyHoursParser.parse(["Hours vary", "Please telephone ahead"]) == nil)
  }
}
