import SwiftUI
import WebKit

/// The human-in-the-loop browser — **rung 3** of the field-supplement ladder
/// (ADR-0016 §2): when MapKit and the official-site fetch can't find opening hours,
/// Jon drives an in-app `WKWebView` to the page that has them (it renders JS, holds
/// a real session, handles consent walls), then taps **Use This Page** to run the
/// capture parser over the loaded DOM. The no-server enrichment workhorse.
///
/// Hours grabbed this way are stamped `.unverified` by the caller — they came
/// through a page the user navigated, not an authoritative source.
struct HoursBrowserView: View {
  let startURL: URL
  /// Hand the loaded page's HTML + URL back; returns whether hours were found.
  let onGrabHours: (_ html: String, _ sourceURL: URL?) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var webView = WKWebView()
  @State private var grabbing = false
  @State private var notice: String?

  var body: some View {
    NavigationStack {
      WebContent(webView: webView, url: startURL)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Find Hours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Use This Page") { Task { await grab() } }
              .disabled(grabbing)
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

  /// Pull the rendered DOM and hand it to the parser. Dismisses on a hit; otherwise
  /// leaves the browser open so Jon can navigate to a better page and retry.
  private func grab() async {
    grabbing = true
    notice = nil
    defer { grabbing = false }
    let html = (try? await webView.evaluateJavaScript("document.documentElement.outerHTML")) as? String
    guard let html, !html.isEmpty else {
      notice = "Couldn't read this page — try again once it's loaded."
      return
    }
    if await onGrabHours(html, webView.url) {
      dismiss()
    } else {
      notice = "No hours found on this page. Navigate to the hours and try again."
    }
  }
}

/// A thin `WKWebView` host. The `webView` is owned by the SwiftUI view so its DOM
/// can be queried after load; navigation (tapping links, consent) is the user's.
private struct WebContent: UIViewRepresentable {
  let webView: WKWebView
  let url: URL

  func makeUIView(context: Context) -> WKWebView {
    webView.load(URLRequest(url: url))
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}
}
