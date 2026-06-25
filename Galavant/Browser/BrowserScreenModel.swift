import Dependencies
import Foundation
import GalavantWeb
import Sharing

/// A page grabbed from the in-app browser, awaiting confirm-and-tweak. Identifiable so a
/// `.sheet(item:)` can present the capture confirm sheet over it (ADR-0023).
struct BrowserCapture: Identifiable {
  let id = UUID()
  let html: String
  let sourceURL: URL?
}

/// Drives the top-level Browser section (ADR-0023): a small launcher (address/search
/// field + recent destinations) that opens `WebExtractorBrowser` modally, and the
/// hand-off from a "Capture" grab to the shared capture confirm sheet.
///
/// The browser is the app-agnostic `GalavantWeb` component (ADR-0022) presented as a
/// modal extractor — the deliberate v1 surface (ADR-0023): no in-browser address bar, so
/// a new destination means returning here. The grab → confirm hand-off runs through
/// `onDismiss` so the confirm sheet presents only after the browser has fully dismissed
/// (two sheets presenting at once is dropped by SwiftUI).
@MainActor
@Observable
final class BrowserScreenModel {
  var address = ""
  /// Set to present the modal browser at this URL; cleared on dismiss.
  var browseURL: URL?
  /// Set (via `browserDismissed`) to present the capture confirm sheet after a grab.
  var capture: BrowserCapture?

  /// The recently-opened destinations, newest first, persisted across launches as a
  /// newline-joined string (mirrors the app's other `@Shared(.appStorage)` scalars).
  @ObservationIgnored @Shared(.appStorage("browserRecents")) private var recentsRaw = ""

  /// Stashed between the grab and the browser's full dismissal, so the confirm sheet
  /// presents in `onDismiss` rather than racing the browser's own dismiss.
  @ObservationIgnored private var pending: BrowserCapture?

  /// Turn a non-URL query into a web search. **DuckDuckGo** — no account, no tracking
  /// cookie, no result personalization; the engine whose posture matches the app's
  /// no-server / privacy stance (ADR-0001). One named constant, so swapping the engine
  /// is a one-line edit, not a hunt through string literals.
  static let webSearchPrefix = "https://duckduckgo.com/?q="

  /// Cap on the recent-destinations list. **8** — the launcher shows recents inline
  /// under the address field; ~8 rows is a phone screenful without scrolling, and the
  /// list is a convenience, not a history (the captured ideas are the real record). A UI
  /// list length, not a data limit.
  static let maxRecents = 8

  /// The recent destinations as URLs, newest first.
  var recents: [URL] {
    recentsRaw.split(separator: "\n").compactMap { URL(string: String($0)) }
  }

  /// Open the browser at the resolved address (a URL, a bare domain, or a search).
  func go() {
    guard let url = Self.resolve(address) else { return }
    open(url)
  }

  /// Open the browser directly at a known URL (a recents tap).
  func open(_ url: URL) {
    remember(url)
    browseURL = url
  }

  /// `WebExtractorBrowser`'s plugin: stash the grabbed page and dismiss the browser. The
  /// confirm sheet is presented from `browserDismissed`, not here, so it doesn't race the
  /// dismissal. Always `.extracted` — a capture always succeeds at grabbing the DOM; the
  /// user vets it in the confirm sheet next.
  func captured(html: String, sourceURL: URL?) -> WebExtractionOutcome {
    pending = BrowserCapture(html: html, sourceURL: sourceURL)
    return .extracted
  }

  /// Promote a stashed grab into the presented confirm sheet, once the browser sheet has
  /// finished dismissing. A plain Cancel (no grab) leaves `pending` nil — a no-op.
  func browserDismissed() {
    guard let pending else { return }
    capture = pending
    self.pending = nil
  }

  /// Tear down the confirm sheet (saved or cancelled).
  func captureFinished() {
    capture = nil
  }

  /// Resolve typed text to a destination URL: an explicit scheme is honored; a bare
  /// single-token domain (`michelin.com/…`) gets `https://`; anything else (spaces, no
  /// dot) becomes a web search. `nil` only for empty input.
  static func resolve(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil { return url }
    if !trimmed.contains(" "), trimmed.contains("."),
      let url = URL(string: "https://\(trimmed)")
    {
      return url
    }
    let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
    return URL(string: "\(webSearchPrefix)\(query)")
  }

  /// Record a destination at the front of the recents list, de-duplicated and capped.
  private func remember(_ url: URL) {
    var urls = recents.filter { $0 != url }
    urls.insert(url, at: 0)
    let capped = urls.prefix(Self.maxRecents).map(\.absoluteString)
    $recentsRaw.withLock { $0 = capped.joined(separator: "\n") }
  }
}
