import Dependencies
import Foundation
import LLMClientKit
import GalavantCapture
import GalavantSchema
import Testing

@testable import GalavantPlaces

/// The on-device hours LLM fallback's tolerant parse (ADR-0016 §2; docs/BACKLOG.md).
/// The extraction itself runs no model offline (`testValue` → nil); these cover the
/// defensive parse so a chatty or malformed reply degrades to `nil`, never a crash.
@Suite struct HoursExtractorTests {
  @Test("Parses a clean JSON object")
  func cleanObject() {
    #expect(HoursExtractor.parse(#"{"hours": "Mon–Fri 9:00–17:00"}"#) == "Mon–Fri 9:00–17:00")
  }

  @Test("Null or blank hours degrade to nil")
  func nullOrBlank() {
    #expect(HoursExtractor.parse(#"{"hours": null}"#) == nil)
    #expect(HoursExtractor.parse(#"{"hours": "   "}"#) == nil)
    #expect(HoursExtractor.parse(#"{"open": "Mon 9–5"}"#) == nil)  // wrong key
  }

  @Test("Chatty prose around the object still parses")
  func chattyWrapped() {
    let reply = "Sure! Here are the hours:\n{\"hours\": \"Daily 10:00–22:00\"}\nHope that helps."
    #expect(HoursExtractor.parse(reply) == "Daily 10:00–22:00")
  }

  @Test("Malformed output degrades to nil, never crashes")
  func malformed() {
    #expect(HoursExtractor.parse("no json here") == nil)
    #expect(HoursExtractor.parse("{not valid json}") == nil)
    #expect(HoursExtractor.parse("") == nil)
  }

  @Test("Live extraction feeds the model bodyText, where bottom-of-page hours live")
  func liveReadsBodyText() async {
    // The summary excerpt clips before a footer's hours; the model only sees them
    // because the extractor reads the fuller bodyText (the das-achental fix).
    let page = ParsedPage(
      title: "es:senz",
      textExcerpt: "A Michelin-starred restaurant on Lake Chiemsee.",
      bodyText: "A Michelin-starred restaurant on Lake Chiemsee. "
        + "Chiemgau Pur - Fine Dining Wednesday - Saturday 6.30 -11 pm."
    )
    let hours = await withDependencies {
      $0.modelClient = StubModelClient { request in
        let prompt = request.messages.last?.text ?? ""
        #expect(prompt.contains("Wednesday - Saturday 6.30 -11 pm"))
        return ModelResponse(text: #"{"hours": "Wednesday - Saturday 6.30 -11 pm"}"#)
      }
    } operation: {
      await HoursExtractor.liveValue(page)
    }
    #expect(hours == "Wednesday - Saturday 6.30 -11 pm")
  }

  // MARK: Structured parse (ADR-0029 §3.2)

  @Test("Structured parse decodes a weekly schedule with a labeled meal")
  func structuredWithMeal() throws {
    let json = """
      {"week":[
        {"day":"tuesday","status":"open","periods":[{"meal":"dinner","open":"18:00","close":"22:00"}]},
        {"day":"monday","status":"closed"}
      ]}
      """
    let hours = try #require(HoursExtractor.parseStructured(json))
    #expect(hours[.tuesday].serves(.dinner) == true)
    #expect(hours[.tuesday] == .open([ServicePeriod(meal: .dinner, interval: OpenInterval(open: 1080, close: 1320))]))
    #expect(hours[.monday] == .closed)
    // A day the model didn't mention stays unknown, never closed.
    #expect(hours[.wednesday] == .unknown)
  }

  @Test("Prose-only meal (dinner only, no times) keeps meal, no fabricated clock")
  func structuredDinnerOnly() throws {
    let json = #"{"week":[{"day":"friday","status":"open","periods":[{"meal":"dinner"}]}]}"#
    let hours = try #require(HoursExtractor.parseStructured(json))
    #expect(hours[.friday] == .open([ServicePeriod(meal: .dinner)]))
    #expect(hours[.friday].serves(.dinner) == true)
    #expect(hours[.friday].serves(.lunch) == false)
  }

  @Test("Split lunch/dinner becomes two periods")
  func structuredSplitService() throws {
    let json = """
      {"week":[{"day":"saturday","status":"open","periods":[
        {"open":"12:00","close":"14:00"},{"open":"19:00","close":"22:00"}]}]}
      """
    let hours = try #require(HoursExtractor.parseStructured(json))
    #expect(hours[.saturday].serves(.lunch) == true)
    #expect(hours[.saturday].serves(.dinner) == true)
  }

  @Test("late night wording normalizes to the lateNight meal")
  func structuredLateNight() throws {
    let json = #"{"week":[{"day":"friday","status":"open","periods":[{"meal":"late night"}]}]}"#
    let hours = try #require(HoursExtractor.parseStructured(json))
    #expect(hours[.friday] == .open([ServicePeriod(meal: .lateNight)]))
  }

  @Test("Malformed or empty structured output degrades to nil")
  func structuredMalformed() {
    #expect(HoursExtractor.parseStructured("no json") == nil)
    #expect(HoursExtractor.parseStructured(#"{"week": "nope"}"#) == nil)
    // A week that asserts nothing (all unknown / unrecognized) → nil, not an empty blob.
    #expect(HoursExtractor.parseStructured(#"{"week":[{"day":"funday","status":"open"}]}"#) == nil)
    #expect(HoursExtractor.parseStructured(#"{"week":[{"day":"monday","status":"unknown"}]}"#) == nil)
  }
}
