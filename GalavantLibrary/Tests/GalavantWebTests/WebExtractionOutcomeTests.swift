import Testing

@testable import GalavantWeb

/// `GalavantWeb` is a UI module (the `WebExtractorBrowser` view is exercised through the
/// app), so the only pure surface to assert is the plugin's result type — the seam the
/// caller reports back across.
@Suite struct WebExtractionOutcomeTests {
  @Test("notFound carries its message and differs from extracted")
  func outcomeIdentity() {
    #expect(WebExtractionOutcome.extracted == .extracted)
    #expect(WebExtractionOutcome.notFound(message: "a") == .notFound(message: "a"))
    #expect(WebExtractionOutcome.notFound(message: "a") != .notFound(message: "b"))
    #expect(WebExtractionOutcome.extracted != .notFound(message: "a"))
  }
}
