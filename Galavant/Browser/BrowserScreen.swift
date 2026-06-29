import GalavantCaptureUI
import GalavantPlaces
import GalavantWeb
import SwiftUI

/// The top-level **Browser** section (ADR-0025): a persistent, full-chrome browser in the
/// detail panel — address bar, back / forward / refresh / stop, desktop-width rendering,
/// and a held session that reaches paywalled sources. It hosts the app-agnostic
/// `WebBrowserView` (GalavantWeb) and wires the app-specific bits: recents (the home
/// surface + `onNavigate` recording) and a "Capture" action that grabs the rendered DOM
/// and runs the *same* capture confirm sheet the share extension uses — so capture inherits
/// vet-at-source and the ADR-0019 dedup banner.
///
/// No `NavigationStack` of its own — the `AppContainer` detail/tab column already provides
/// one (nesting another traps the iPad split view), and `WebBrowserView` renders its chrome
/// as plain bars, not a second navigation bar.
struct BrowserScreen: View {
  @State private var model = BrowserScreenModel()

  var body: some View {
    WebBrowserView(
      onNavigate: { model.remember($0) },
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
      home: { open in
        BrowserHome(recents: model.recents, open: open)
      }
    )
    .navigationTitle("Browser")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .sheet(item: $model.capture) { payload in
      CaptureConfirmView(
        model: CaptureModel(html: payload.html, sourceURL: payload.sourceURL)
      ) {
        model.captureFinished()
      }
    }
  }
}

/// The browser's start surface, shown before anything is loaded: a hint and the recent
/// destinations. Tapping a recent navigates through the browser's `open` (which records it
/// and loads it); the address bar is the other way in.
private struct BrowserHome: View {
  let recents: [URL]
  let open: (URL) -> Void

  var body: some View {
    if recents.isEmpty {
      ContentUnavailableView(
        "Browse to a place",
        systemImage: "globe",
        description: Text("Enter an address or search above, then tap Capture to add a place to your pool.")
      )
    } else {
      List {
        Section("Recent") {
          ForEach(recents, id: \.self) { url in
            Button {
              open(url)
            } label: {
              Label(url.host() ?? url.absoluteString, systemImage: "clock.arrow.circlepath")
                .lineLimit(1)
                .foregroundStyle(.primary)
            }
          }
        }
      }
    }
  }
}
