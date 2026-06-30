import Foundation
import GalavantPlaces
import GalavantWeb
import Sharing
import WebKit

/// Accumulated field values from the browser's tap-to-fill chip bar (ADR-0025 §5).
/// Each property is set by tapping the corresponding chip after selecting text on the page.
/// Carried into `CaptureModel.draftOverrides` when "Capture" is tapped, then reset.
struct ChipDraft {
  var name: String?
  var address: String?
  var notes: String?
  var openingHours: String?

  var hasAnyFill: Bool { name != nil || address != nil || notes != nil || openingHours != nil }

  func toOverride() -> CaptureDraftOverride {
    CaptureDraftOverride(name: name, address: address, notes: notes, openingHours: openingHours)
  }

  mutating func appendNotes(_ s: String) {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    notes = notes.map { $0 + "\n" + trimmed } ?? trimmed
  }
}

/// A place captured from the in-app browser, awaiting confirm-and-tweak. Holds the
/// `CaptureModel` so the screen can read the (possibly user-edited) final draft back out
/// after a save — that's how a saved capture lands in **Recent Captures**. Identifiable so
/// a `.sheet(item:)` can present the confirm sheet over it (ADR-0023).
struct BrowserCapture: Identifiable {
  let id = UUID()
  let model: CaptureModel
  let sourceURL: URL?
}

/// One entry in the browser's **Recent Captures** home surface: the captured place's name
/// and the page it came from. Recorded when a capture is *saved* (not on navigation) — the
/// recents are "places I added," not "URLs I typed," which are two different things.
/// Persisted locally (`@Shared(.appStorage)`); the captured ideas themselves are the synced
/// record, so this convenience list stays device-local.
struct RecentCapture: Identifiable, Codable, Hashable {
  var name: String
  var url: URL?
  var id: String { (url?.absoluteString ?? "") + "\u{1F}" + name }
}

/// Drives the top-level Browser section (ADR-0025): the persistent, full-chrome
/// `WebBrowserView` lives in the detail panel; this model owns only the app-side state
/// around it — the **Recent Captures** its home surface lists, and the hand-off from a
/// "Capture" grab to the shared capture confirm sheet.
///
/// Navigation, address bar, and back/forward live in `WebBrowserView`; this model is no
/// longer a launcher. Capture presents `CaptureConfirmView` directly (the browser is
/// persistent, not a sheet, so there is no two-sheets-racing dance anymore).
@MainActor
@Observable
final class BrowserScreenModel {
  /// The single, long-lived web page for the Browser section. Owned here (not in
  /// `WebBrowserView`'s `@State`) so navigation state survives switching sections — the
  /// detail column reinstantiates the screen view, but this model outlives it.
  let page = WebPage.browser(contentMode: .desktop)

  /// Set to present the capture confirm sheet after a grab.
  var capture: BrowserCapture?

  /// Accumulated tap-to-fill values from the chip bar. Reset when "Capture" fires.
  var chipDraft = ChipDraft()

  /// Field-chip descriptors wired to `chipDraft`. Recomputed whenever `chipDraft`
  /// changes (the model is `@Observable`), so the bar's `isFilled` state stays live.
  var captureFields: [WebCaptureField] {
    [
      WebCaptureField(
        id: "name", label: "Name", systemImage: "textformat",
        isFilled: chipDraft.name != nil
      ) { [weak self] s in self?.chipDraft.name = s },
      WebCaptureField(
        id: "hours", label: "Hours", systemImage: "clock",
        isFilled: chipDraft.openingHours != nil
      ) { [weak self] s in self?.chipDraft.openingHours = s },
      WebCaptureField(
        id: "address", label: "Address", systemImage: "mappin",
        isFilled: chipDraft.address != nil
      ) { [weak self] s in self?.chipDraft.address = s },
      WebCaptureField(
        id: "notes", label: "Notes", systemImage: "note.text",
        isFilled: chipDraft.notes != nil
      ) { [weak self] s in self?.chipDraft.appendNotes(s) },
    ]
  }

  /// The recently *captured* places, newest first, persisted across launches as a JSON
  /// blob (a richer payload than the app's scalar `@Shared` strings — name + URL per row).
  @ObservationIgnored @Shared(.appStorage("browserRecentCaptures")) private var recentCapturesRaw = ""

  /// Cap on the Recent Captures list. **8** — the home surface shows it; ~8 rows is a
  /// screenful, and it's a convenience, not a history (the captured ideas are the real,
  /// synced record). A UI list length, not a data limit.
  static let maxRecents = 8

  /// The recent captures as values, newest first.
  var recentCaptures: [RecentCapture] {
    (try? JSONDecoder().decode([RecentCapture].self, from: Data(recentCapturesRaw.utf8))) ?? []
  }

  /// Grab the browser's rendered DOM and present the confirm sheet over it. A blank grab
  /// (page not yet loaded) is a no-op. The confirm sheet runs the same capture pipeline
  /// the share extension uses — vet-at-source + ADR-0019 dedup.
  ///
  /// If the chip bar has any pre-filled fields they are carried into `CaptureModel` as
  /// `draftOverrides` so they win over the auto-parser at the end of `prepare()`.
  func capture(from page: WebPage) async {
    guard let html = await page.currentDOM(), !html.isEmpty else { return }
    let model = CaptureModel(html: html, sourceURL: page.url)
    if chipDraft.hasAnyFill { model.draftOverrides = chipDraft.toOverride() }
    capture = BrowserCapture(model: model, sourceURL: page.url)
  }

  /// Tear down the confirm sheet (saved or cancelled). On a *save*, record the place in
  /// Recent Captures from the final (possibly edited) draft — cancels record nothing.
  func captureFinished() {
    if let capture, capture.model.phase == .saved {
      record(name: capture.model.draft.name, url: capture.sourceURL)
      chipDraft = ChipDraft()
    }
    capture = nil
  }

  /// Add a saved capture to the front of Recent Captures, de-duplicated and capped. A
  /// blank name (nothing worth listing) is skipped.
  private func record(name: String, url: URL?) {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    let entry = RecentCapture(name: clean, url: url)
    var items = recentCaptures.filter { $0.id != entry.id }
    items.insert(entry, at: 0)
    let capped = Array(items.prefix(Self.maxRecents))
    if let data = try? JSONEncoder().encode(capped) {
      $recentCapturesRaw.withLock { $0 = String(decoding: data, as: UTF8.self) }
    }
  }
}
