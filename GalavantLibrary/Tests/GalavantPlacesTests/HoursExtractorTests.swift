import Foundation
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
}
