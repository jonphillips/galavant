import Foundation

/// Pure address-bar resolution for the in-app browser (ADR-0025): turn whatever the user
/// typed into a destination URL. App-agnostic — the search engine is injected, so the
/// module carries no opinion about *which* engine (the app supplies one; `duckDuckGo` is
/// the default that matches the no-tracking posture, ADR-0001).
public enum WebAddress {
  /// A DuckDuckGo search URL for `query` — no account, no tracking cookie, no result
  /// personalization. The module's default `search` builder; one place to swap the engine.
  public static func duckDuckGo(_ query: String) -> URL? {
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    return URL(string: "https://duckduckgo.com/?q=\(encoded)")
  }

  /// Resolve typed text to a destination: an explicit scheme is honored; a bare
  /// single-token domain (`michelin.com/…`) gets `https://`; anything else (spaces, or no
  /// dot) becomes a search via `search`. `nil` only for empty input (or a `search` that
  /// returns `nil`).
  public static func resolve(
    _ text: String,
    search: (String) -> URL? = WebAddress.duckDuckGo
  ) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil { return url }
    if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://\(trimmed)") {
      return url
    }
    return search(trimmed)
  }
}
