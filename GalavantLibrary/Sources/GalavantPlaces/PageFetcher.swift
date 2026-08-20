import Dependencies
import Foundation
import GalavantCapture
import WebExtractorKit

/// A Safari-like User-Agent — many travel sites serve a fuller, more parseable page
/// to a browser than to a bare client. Shared by the page and image fetchers.
enum CaptureUserAgent {
  static let safari =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
}

/// A fetched document together with the URL that actually produced it after any
/// redirects. The effective URL is the base for resolving relative links and images;
/// it is not written back to the idea's user-supplied URL.
public struct FetchedDocument: Sendable {
  public var html: String
  public var effectiveURL: URL

  public init(html: String, effectiveURL: URL) {
    self.html = html
    self.effectiveURL = effectiveURL
  }
}

/// Fetches a page document for the app-side **second enrichment hop** (M4g): the
/// place's own website, re-parsed for better images + facts than the originally
/// shared page (often an aggregator) gave. The document carries the effective URL
/// after redirects so relative values resolve against the page that was fetched.
/// Injectable so `PlaceEnricher` is testable with a fixture page and no network.
public struct PageFetcher: Sendable {
  var fetch: @Sendable (_ url: URL) async -> FetchedDocument?

  public init(fetch: @escaping @Sendable (_ url: URL) async -> FetchedDocument?) {
    self.fetch = fetch
  }

  /// The fetched document, or nil on any failure (best-effort — a failed hop just
  /// leaves the idea as captured).
  public func callAsFunction(_ url: URL) async -> FetchedDocument? {
    await fetch(url)
  }
}

extension PageFetcher: DependencyKey {
  public static let liveValue = PageFetcher { url in
    let target = URLHygiene.httpsUpgraded(url)
    var request = URLRequest(url: target)
    request.setValue(CaptureUserAgent.safari, forHTTPHeaderField: "User-Agent")
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
    else { return nil }
    guard let html = String(data: data, encoding: .utf8) else { return nil }
    return FetchedDocument(html: html, effectiveURL: response.url ?? target)
  }

  /// No network in tests/previews.
  public static let testValue = PageFetcher { _ in nil }
}

extension DependencyValues {
  public var pageFetcher: PageFetcher {
    get { self[PageFetcher.self] }
    set { self[PageFetcher.self] = newValue }
  }
}

/// The **rendered-DOM** counterpart to `PageFetcher` (ADR-0024): same shape and
/// best-effort contract, but the live value loads the URL in a headless WebKit
/// `WebPage` so client-side JavaScript runs before the document is read. Used as a
/// *render-on-miss* fallback — the enrichment paths try the cheap `PageFetcher` GET
/// first and reach for this only when the static parse came back empty, which is
/// exactly the JS-shell / SPA / anti-bot pages a rendered DOM fixes. Injectable so the
/// escalation logic is testable with fixtures and no WebKit.
public struct RenderedPageFetcher: Sendable {
  var fetch: @Sendable (_ url: URL) async -> FetchedDocument?

  public init(fetch: @escaping @Sendable (_ url: URL) async -> FetchedDocument?) {
    self.fetch = fetch
  }

  /// The rendered document, or nil on any failure (best-effort, like `PageFetcher`).
  public func callAsFunction(_ url: URL) async -> FetchedDocument? {
    await fetch(url)
  }
}

extension RenderedPageFetcher: DependencyKey {
  public static let liveValue = RenderedPageFetcher { url in
    guard let document = await RenderedDOMFetcher.renderedDocument(
      of: URLHygiene.httpsUpgraded(url)
    ) else { return nil }
    return FetchedDocument(html: document.html, effectiveURL: document.effectiveURL)
  }

  /// No WebKit in tests/previews — the escalation logic is exercised with fixtures.
  public static let testValue = RenderedPageFetcher { _ in nil }
}

extension DependencyValues {
  public var renderedPageFetcher: RenderedPageFetcher {
    get { self[RenderedPageFetcher.self] }
    set { self[RenderedPageFetcher.self] = newValue }
  }
}
