import Foundation
import WebKit

/// Headless rendered-DOM acquisition (ADR-0024): load a URL in a viewless `WebPage`,
/// let its JavaScript run, and return the rendered `outerHTML`. The *unattended*
/// counterpart to `WebExtractorBrowser` — same "render the page's DOM via WebKit, know
/// no domain" charter, but no UI and no human. Callers use it as a render-on-miss
/// fallback: try a cheap `URLSession` GET first, render only when that parses to nothing.
///
/// Best-effort by contract: `nil` on any failure (network timeout, web-content process
/// termination, invalid URL), mirroring the raw fetch path it backs up.
///
/// `WebPage` (iOS/macOS 26+) is the SDK's headless engine — `load` + `callJavaScript`,
/// no view — verified against the Xcode-beta WebKit interface; the package's platforms
/// already require 26, so no availability gate is needed.
public enum RenderedDOMFetcher {
  @MainActor public static func renderedHTML(of url: URL) async -> String? {
    let page = WebPage()
    do {
      // `load` is an async event stream; `.finished` is the render-complete signal
      // (main-frame navigation done). The request's default timeout (60s) bounds a
      // hung load — the same bound the raw `URLSession` path already lives under.
      for try await event in page.load(URLRequest(url: url)) {
        if event == .finished { break }
      }
      // `callJavaScript` runs a function *body*, so the expression needs `return`.
      return try await page.callJavaScript("return document.documentElement.outerHTML")
        as? String
    } catch {
      return nil
    }
  }
}
