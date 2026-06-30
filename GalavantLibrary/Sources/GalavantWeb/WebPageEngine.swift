import Foundation
import WebKit

/// Shared `WebPage` substrate for `GalavantWeb` (ADR-0025). `WebPage` is the SDK's
/// `@Observable` WebKit engine; the interactive browser shows it via SwiftUI `WebView`,
/// the headless `RenderedDOMFetcher` loads it viewless — one engine, both modes.

extension WebPage {
  /// A `WebPage` configured for the in-app browser: the requested content mode and the
  /// **default persistent** website data store. Persistence is the point — a login
  /// (paywalled source) survives across launches because cookies live in the default
  /// store; never swap in a non-persistent store (ADR-0025 §4).
  static func browser(
    contentMode: WebPage.NavigationPreferences.ContentMode = .recommended
  ) -> WebPage {
    var configuration = WebPage.Configuration()
    configuration.defaultNavigationPreferences.preferredContentMode = contentMode
    return WebPage(configuration: configuration)
  }

  /// The page's rendered DOM (`document.documentElement.outerHTML`), or `nil` on failure.
  /// The single app-agnostic capture primitive shared by the interactive browser and the
  /// headless fetcher. `callJavaScript` runs a function *body*, so the expression needs
  /// `return`.
  public func currentDOM() async -> String? {
    (try? await callJavaScript("return document.documentElement.outerHTML")) as? String
  }

  /// The user's current on-page text selection, or an empty string when nothing is
  /// selected or the script fails. Used by the field-capture bar to fill a chip field
  /// from a selection the user made before tapping the chip.
  public func currentSelection() async -> String {
    (try? await callJavaScript("return window.getSelection().toString()")) as? String ?? ""
  }
}
