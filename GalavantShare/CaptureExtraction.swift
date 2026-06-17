import Foundation
import UniformTypeIdentifiers

/// Pulls the shared page out of the extension context. Prefers the JS
/// preprocessing results (Safari's rendered DOM via `ExtensionPreProcessing.js`);
/// falls back to a plain shared URL, fetching its raw HTML with a Safari-like
/// User-Agent (single-hop — the second enrichment hop is deferred to the app).
enum CaptureExtraction {
  struct Input {
    var html: String
    var url: URL?
  }

  static func input(from context: NSExtensionContext?) async -> Input {
    let items = (context?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }

    // 1. Rendered DOM from the JS preprocessor.
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
      guard
        let loaded = try? await provider.loadItem(
          forTypeIdentifier: UTType.propertyList.identifier
        ),
        let results = loaded as? NSDictionary,
        let js = results[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
      else { continue }
      let html = js["html"] as? String ?? ""
      let url = (js["url"] as? String).flatMap(URL.init(string:))
      if !html.isEmpty { return Input(html: html, url: url) }
    }

    // 2. Fallback: a bare URL share — fetch the page ourselves.
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      guard
        let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
        let url = loaded as? URL
      else { continue }
      return Input(html: await fetchHTML(url), url: url)
    }

    return Input(html: "", url: nil)
  }

  private static func fetchHTML(_ url: URL) async -> String {
    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
}
