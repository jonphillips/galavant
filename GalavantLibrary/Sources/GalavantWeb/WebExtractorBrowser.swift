import SwiftUI
import WebKit

/// The outcome of a caller's extraction attempt over a page's rendered DOM (ADR-0022).
/// App-agnostic: the browser only learns *whether* to dismiss, never *what* was found.
public enum WebExtractionOutcome: Equatable, Sendable {
  /// The page yielded what the caller needed — the browser dismisses.
  case extracted
  /// Nothing usable here — the browser stays open with `message` so the user can
  /// navigate somewhere better and try again.
  case notFound(message: String)
}

/// An app-agnostic in-app browser presented as a **modal extraction session**: load a
/// start URL, let the user navigate / clear consent, and on confirm hand the page's
/// **rendered DOM** (`outerHTML`) plus the current URL to an injected `onExtract` plugin
/// (ADR-0022). The persistent, full-chrome counterpart is `WebBrowserView`; this stays
/// the focused "go fetch one thing and come back" surface its in-form consumers want.
///
/// Built on `WebPage` + SwiftUI `WebView` (ADR-0025) — the same engine the headless
/// `RenderedDOMFetcher` drives viewless. The plugin (on the caller's side, free to import
/// any domain type) turns the HTML into whatever the app needs and reports back a
/// `WebExtractionOutcome`. That one-way seam lets this module drop into another app
/// unchanged.
public struct WebExtractorBrowser: View {
  let startURL: URL
  let title: String
  let confirmLabel: String
  /// The plugin: hand the rendered HTML + current URL to the caller; it decides the
  /// outcome. `async` so the caller can parse/persist before answering.
  let onExtract: (_ html: String, _ sourceURL: URL?) async -> WebExtractionOutcome

  public init(
    startURL: URL,
    title: String,
    confirmLabel: String,
    onExtract: @escaping (_ html: String, _ sourceURL: URL?) async -> WebExtractionOutcome
  ) {
    self.startURL = startURL
    self.title = title
    self.confirmLabel = confirmLabel
    self.onExtract = onExtract
  }

  @Environment(\.dismiss) private var dismiss
  @State private var page = WebPage.browser()
  @State private var working = false
  @State private var notice: String?

  public var body: some View {
    NavigationStack {
      WebView(page)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(title)
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(confirmLabel) { Task { await grab() } }
              .disabled(working)
          }
        }
        .safeAreaInset(edge: .bottom) {
          if let notice {
            Text(notice)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .padding(8)
              .frame(maxWidth: .infinity)
              .background(.bar)
          }
        }
        .task {
          // Drive the start-URL load to completion; the view reflects progress via the
          // observable `WebPage`. Best-effort — a load failure leaves the user on a blank
          // page they can navigate from.
          do {
            for try await _ in page.load(URLRequest(url: startURL)) {}
          } catch {}
        }
    }
  }

  /// Pull the rendered DOM and hand it to the plugin. Dismisses on `.extracted`;
  /// otherwise leaves the browser open and shows the plugin's message so the user can
  /// navigate to a better page and retry.
  private func grab() async {
    working = true
    notice = nil
    defer { working = false }
    guard let html = await page.currentDOM(), !html.isEmpty else {
      notice = "Couldn't read this page — try again once it's loaded."
      return
    }
    switch await onExtract(html, page.url) {
    case .extracted:
      dismiss()
    case .notFound(let message):
      notice = message
    }
  }
}
