import Foundation
import GalavantWeb
import Sharing
import WebKit

/// A page grabbed from the in-app browser, awaiting confirm-and-tweak. Identifiable so a
/// `.sheet(item:)` can present the capture confirm sheet over it (ADR-0023).
struct BrowserCapture: Identifiable {
  let id = UUID()
  let html: String
  let sourceURL: URL?
}

/// Drives the top-level Browser section (ADR-0025): the persistent, full-chrome
/// `WebBrowserView` lives in the detail panel; this model owns only the app-side state
/// around it — the recent destinations its home surface lists, and the hand-off from a
/// "Capture" grab to the shared capture confirm sheet.
///
/// Navigation, address bar, and back/forward live in `WebBrowserView`; this model is no
/// longer a launcher. Capture presents `CaptureConfirmView` directly (the browser is
/// persistent, not a sheet, so there is no two-sheets-racing dance anymore).
@MainActor
@Observable
final class BrowserScreenModel {
  /// Set to present the capture confirm sheet after a grab.
  var capture: BrowserCapture?

  /// The recently-opened destinations, newest first, persisted across launches as a
  /// newline-joined string (mirrors the app's other `@Shared(.appStorage)` scalars).
  @ObservationIgnored @Shared(.appStorage("browserRecents")) private var recentsRaw = ""

  /// Cap on the recent-destinations list. **8** — the browser's home surface shows
  /// recents; ~8 rows is a screenful, and the list is a convenience, not a history (the
  /// captured ideas are the real record). A UI list length, not a data limit.
  static let maxRecents = 8

  /// The recent destinations as URLs, newest first.
  var recents: [URL] {
    recentsRaw.split(separator: "\n").compactMap { URL(string: String($0)) }
  }

  /// Record a destination at the front of the recents list, de-duplicated and capped.
  /// Wired to `WebBrowserView`'s `onNavigate`, so every explicit navigation lands here.
  func remember(_ url: URL) {
    var urls = recents.filter { $0 != url }
    urls.insert(url, at: 0)
    let capped = urls.prefix(Self.maxRecents).map(\.absoluteString)
    $recentsRaw.withLock { $0 = capped.joined(separator: "\n") }
  }

  /// Grab the browser's rendered DOM and present the confirm sheet over it. A blank grab
  /// (page not yet loaded) is a no-op. The confirm sheet runs the same capture pipeline
  /// the share extension uses — vet-at-source + ADR-0019 dedup.
  func capture(from page: WebPage) async {
    guard let html = await page.currentDOM(), !html.isEmpty else { return }
    capture = BrowserCapture(html: html, sourceURL: page.url)
  }

  /// Tear down the confirm sheet (saved or cancelled).
  func captureFinished() {
    capture = nil
  }
}
