import Foundation
import Testing

@testable import GalavantCapture

@Suite struct TextCleaningTests {
  @Test("Drops a marketing hook question and a trailing CTA, keeps the factual middle")
  func demarketsForestis() {
    let raw =
      "Searching for a boutique wellness hotel in the Dolomites? "
      + "FORESTIS sits at 1,800 metres above Brixen with views of the Plose massif. "
      + "Find out more."
    let cleaned = TextCleaning.demarketed(raw)
    #expect(
      cleaned == "FORESTIS sits at 1,800 metres above Brixen with views of the Plose massif."
    )
  }

  @Test("Leaves a clean factual description untouched")
  func leavesFactualUntouched() {
    let raw = "A three-Michelin-star Nordic restaurant in central Copenhagen."
    #expect(TextCleaning.demarketed(raw) == raw)
  }

  @Test("Returns nil when only marketing survives")
  func nilWhenAllMarketing() {
    #expect(TextCleaning.demarketed("Book now! Discover more. Sign up today.") == nil)
    #expect(TextCleaning.demarketed("") == nil)
    #expect(TextCleaning.demarketed(nil) == nil)
  }

  @Test("Keeps a genuine, non-hook question")
  func keepsRealQuestion() {
    let raw = "What is Noma? It is a Nordic tasting-menu restaurant."
    #expect(TextCleaning.demarketed(raw) == raw)
  }
}
