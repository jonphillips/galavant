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

/// An app-agnostic in-app browser. It owns the **act of browsing** — load a URL,
/// render JavaScript, hold a real session, and let the user navigate and clear consent
/// walls — and when the user taps the confirm button it hands the page's **rendered
/// DOM** (`outerHTML`) plus the current URL to an injected `onExtract` plugin.
///
/// It deliberately knows nothing about any app's domain: the plugin (which lives on the
/// caller's side and *may* import whatever domain types it likes) turns the HTML into
/// whatever the app needs and reports back a `WebExtractionOutcome`. That one-way seam —
/// the browser depends on nothing, the caller wires it to its own extractor — is what
/// lets this module drop into another app unchanged.
///
/// Multiplatform by construction: `WKWebView` is unified across iOS and macOS; only the
/// representable wrapper is `#if`-split (UIKit / AppKit).
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
  @State private var webView = WKWebView()
  @State private var working = false
  @State private var notice: String?

  public var body: some View {
    NavigationStack {
      WebContent(webView: webView, url: startURL)
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
    }
  }

  /// Pull the rendered DOM and hand it to the plugin. Dismisses on `.extracted`;
  /// otherwise leaves the browser open and shows the plugin's message so the user can
  /// navigate to a better page and retry.
  private func grab() async {
    working = true
    notice = nil
    defer { working = false }
    let html = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML")) as? String
    guard let html, !html.isEmpty else {
      notice = "Couldn't read this page — try again once it's loaded."
      return
    }
    switch await onExtract(html, webView.url) {
    case .extracted:
      dismiss()
    case .notFound(let message):
      notice = message
    }
  }
}

/// A thin `WKWebView` host. The `webView` is owned by the SwiftUI view so its DOM can be
/// queried after load; navigation (tapping links, consent) is the user's. The
/// representable conformance is the only platform-split: `WKWebView` itself is unified.
private struct WebContent {
  let webView: WKWebView
  let url: URL
}

#if canImport(UIKit)
  extension WebContent: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
      webView.load(URLRequest(url: url))
      return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
  }
#elseif canImport(AppKit)
  extension WebContent: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
      webView.load(URLRequest(url: url))
      return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}
  }
#endif
