import Foundation
import GalavantCaptureUI
import GalavantSchema
import WebExtractorKit
import SwiftUI
import WebKit

enum BrowserScreenContext {
  case library
  case recommendation(RecommendationBrowserLoadRequest)
}

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
  @Environment(BrowserScreenModel.self) private var model
  var context: BrowserScreenContext = .library

  /// The page a fresh browser session lands on (Jon's choice). Address-bar searches use
  /// Google too (via `searchURL:` below) — Galavant opts out of the module default
  /// (DuckDuckGo, ADR-0001) because place research leans on Google's local results.
  private static let startPage = URL(string: "https://www.google.com")

  var body: some View {
    @Bindable var model = model
    WebBrowserView(
      page: model.page,
      initialURL: initialURL,
      searchURL: WebAddress.google,
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
      fieldBar: fieldBar,
      home: { open in
        BrowserHome(recentCaptures: model.recentCaptures, open: open)
      }
    )
    .navigationTitle("Browser")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onChange(of: model.page.url) { old, new in
      if browsingSite(old) != browsingSite(new) { model.chipDraft = ChipDraft() }
    }
    .task(id: recommendationLoadRequest) {
      guard let request = recommendationLoadRequest, let url = browserURL(for: request.target) else { return }
      guard url != model.page.url else { return }
      model.page.load(URLRequest(url: url))
    }
    .sheet(item: $model.capture) { payload in
      CaptureConfirmView(model: payload.model) {
        model.captureFinished()
      }
    }
  }

  private var initialURL: URL? {
    if case .library = context { Self.startPage } else { nil }
  }

  private var recommendationLoadRequest: RecommendationBrowserLoadRequest? {
    guard case let .recommendation(request) = context else { return nil }
    return request
  }

  @ViewBuilder private func fieldBar(_ page: WebPage) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      WebFieldCaptureBar(
        page: page,
        fields: model.captureFields,
        onClear: model.chipDraft.hasAnyFill ? { model.chipDraft = ChipDraft() } : nil
      )
      if let request = recommendationLoadRequest, let ideaID = request.ideaID {
        Button("Use this website for \(request.title)") {
          model.useCurrentWebsite(for: ideaID)
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func browserURL(for target: BrowserTargetDerivation.Target) -> URL? {
    switch target {
    case let .search(query): WebAddress.google(query)
    case let .website(url): url
    case .unavailable: nil
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

/// The "site" used to decide when a capture draft belongs to a new place: the host
/// with a leading "www." stripped, lowercased. Deliberately not eTLD+1 — a simple,
/// predictable rule; a rare cross-subdomain place costs one re-tap.
private func browsingSite(_ url: URL?) -> String? {
  guard let host = url?.host()?.lowercased() else { return nil }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}
