import GalavantCaptureUI
import GalavantWeb
import SwiftUI

/// The top-level **Browser** section (ADR-0025): a persistent, full-chrome browser in the
/// detail panel — address bar, back / forward / refresh / stop, desktop-width rendering,
/// and a held session that reaches paywalled sources. It hosts the app-agnostic
/// `WebBrowserView` (GalavantWeb) and wires the app-specific bits: the start page
/// (google.com), the **Recent Captures** home surface, and a "Capture" action that grabs
/// the rendered DOM and runs the *same* capture confirm sheet the share extension uses —
/// so capture inherits vet-at-source and the ADR-0019 dedup banner. A saved capture is
/// recorded into Recent Captures (places added, not URLs typed).
///
/// No `NavigationStack` of its own — the `AppContainer` detail/tab column already provides
/// one (nesting another traps the iPad split view), and `WebBrowserView` renders its chrome
/// as plain bars, not a second navigation bar.
struct BrowserScreen: View {
  @State private var model = BrowserScreenModel()

  /// The page a fresh browser session lands on (Jon's choice). The address bar's
  /// no-URL *search* still uses the module default (DuckDuckGo, ADR-0001) — this is only
  /// the start page, not the search engine.
  private static let startPage = URL(string: "https://www.google.com")

  var body: some View {
    WebBrowserView(
      initialURL: Self.startPage,
      accessory: { page in
        Button {
          Task { await model.capture(from: page) }
        } label: {
          Label("Capture", systemImage: "plus.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.semibold))
        }
        .disabled(page.url == nil)
      },
      fieldBar: { page in
        WebFieldCaptureBar(page: page, fields: model.captureFields)
      },
      home: { open in
        BrowserHome(recentCaptures: model.recentCaptures, open: open)
      }
    )
    .navigationTitle("Browser")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .sheet(item: $model.capture) { payload in
      CaptureConfirmView(model: payload.model) {
        model.captureFinished()
      }
    }
  }
}

/// The browser's home surface, reachable via the toolbar home button: the places you
/// recently *captured* (not URLs you typed — two different things). Tapping one reopens
/// the page it came from through the browser's `open`; the address bar is the other way in.
private struct BrowserHome: View {
  let recentCaptures: [RecentCapture]
  let open: (URL) -> Void

  var body: some View {
    if recentCaptures.isEmpty {
      ContentUnavailableView(
        "No captures yet",
        systemImage: "bookmark",
        description: Text("Browse to a place and tap Capture to add it to your pool.")
      )
    } else {
      List {
        Section("Recent Captures") {
          ForEach(recentCaptures) { capture in
            Button {
              if let url = capture.url { open(url) }
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 2) {
                  Text(capture.name).foregroundStyle(.primary).lineLimit(1)
                  if let host = capture.url?.host() {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
              } icon: {
                Image(systemName: "bookmark")
              }
            }
            .disabled(capture.url == nil)
          }
        }
      }
    }
  }
}
