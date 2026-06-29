import Foundation
import Testing

@testable import GalavantWeb

/// `WebAddress.resolve` is the browser's pure address-bar logic (ADR-0025): typed text →
/// destination URL. A fixed `search` builder keeps the search branch deterministic.
@Suite struct WebAddressTests {
  /// A stand-in search engine so the search branch doesn't depend on the DuckDuckGo URL.
  private func search(_ query: String) -> URL? {
    URL(string: "https://search.example/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
  }

  @Test("an explicit scheme is honored verbatim")
  func explicitScheme() {
    #expect(
      WebAddress.resolve("https://michelin.com/guide", search: search)
        == URL(string: "https://michelin.com/guide")
    )
  }

  @Test("a bare single-token domain gets https://")
  func bareDomain() {
    #expect(
      WebAddress.resolve("eater.com/maps", search: search)
        == URL(string: "https://eater.com/maps")
    )
  }

  @Test("multi-word text becomes a search")
  func multiWordSearch() {
    #expect(
      WebAddress.resolve("best ramen tokyo", search: search)
        == URL(string: "https://search.example/?q=best%20ramen%20tokyo")
    )
  }

  @Test("a single dotless token becomes a search, not a domain")
  func dotlessToken() {
    #expect(
      WebAddress.resolve("michelin", search: search)
        == URL(string: "https://search.example/?q=michelin")
    )
  }

  @Test("empty or whitespace-only input resolves to nil")
  func emptyInput() {
    #expect(WebAddress.resolve("", search: search) == nil)
    #expect(WebAddress.resolve("   ", search: search) == nil)
  }

  @Test("surrounding whitespace is trimmed before resolving")
  func trimsWhitespace() {
    #expect(
      WebAddress.resolve("  apple.com  ", search: search)
        == URL(string: "https://apple.com")
    )
  }

  @Test("the default search builder targets DuckDuckGo")
  func defaultSearchIsDuckDuckGo() {
    #expect(
      WebAddress.resolve("sushi")?.host() == "duckduckgo.com"
    )
  }
}
