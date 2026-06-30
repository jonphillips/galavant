import SwiftUI
import WebKit

/// An app-agnostic, **persistent** in-app browser with full chrome (ADR-0025): an
/// editable address/search bar, back / forward / refresh / stop, a progress bar, and a
/// `WebView` over a long-lived `WebPage`. It renders sites at **desktop** width (the
/// panel is wide; the desktop layout is richer for capture) and holds a real session, so
/// a login to a paywalled source persists across launches via the default data store.
///
/// It knows no app domain. The host plugs in three slots:
/// - `accessory`: bottom-bar affordances built over the live `WebPage` — the "Capture"
///   action. The host reads the rendered DOM with `page.currentDOM()`.
/// - `fieldBar`: a full-width bar between the web content and the bottom nav toolbar —
///   the tap-to-fill field-capture bar (ADR-0025 §5). Receives the live `WebPage` so
///   chips can call `page.currentSelection()`. Omit (or use the convenience init) to
///   get `EmptyView` here.
/// - `home`: a start surface shown when nothing is loaded yet (e.g. recent destinations);
///   it navigates by calling the supplied `open`.
///
/// `onNavigate` fires on every *explicit* navigation (address-bar submit or a `home`
/// `open`), so the host can record recents without the module knowing what a "recent" is.
/// That one-way seam is what lets the whole browser drop into another app unchanged.
///
/// `initialURL` is loaded once on first appearance **only when nothing is already
/// loaded** — a fresh session lands on a useful page (the host's choice), while a
/// browser that already holds a page (a held session across tab switches) is left
/// untouched. The `home` surface is reachable any time via the toolbar's home button.
public struct WebBrowserView<Accessory: View, Home: View, FieldBar: View>: View {
  private let initialURL: URL?
  private let searchURL: (String) -> URL?
  private let onNavigate: (URL) -> Void
  private let accessory: (WebPage) -> Accessory
  private let home: (@escaping (URL) -> Void) -> Home
  /// Full-width bar rendered between the web content and the bottom nav toolbar.
  /// Receives the live `WebPage` so it can call `page.currentSelection()` on chip tap.
  /// `EmptyView` when the host supplies no field bar (the no-arg overload below).
  private let fieldBar: (WebPage) -> FieldBar

  @State private var page = WebPage.browser(contentMode: .desktop)
  @State private var addressText = ""
  @State private var editing = false
  /// Show the `home` surface over the loaded page — the toolbar home button sets it;
  /// any explicit navigation clears it. Distinct from "no page loaded yet" so home is
  /// reachable even while a page (e.g. the auto-loaded `initialURL`) is showing.
  @State private var showingHome = false
  @FocusState private var addressFocused: Bool

  /// Full initializer — host supplies a field-capture bar in addition to the action
  /// accessory and home surface.
  public init(
    initialURL: URL? = nil,
    searchURL: @escaping (String) -> URL? = WebAddress.duckDuckGo,
    onNavigate: @escaping (URL) -> Void = { _ in },
    @ViewBuilder accessory: @escaping (WebPage) -> Accessory,
    @ViewBuilder fieldBar: @escaping (WebPage) -> FieldBar,
    @ViewBuilder home: @escaping (_ open: @escaping (URL) -> Void) -> Home
  ) {
    self.initialURL = initialURL
    self.searchURL = searchURL
    self.onNavigate = onNavigate
    self.accessory = accessory
    self.fieldBar = fieldBar
    self.home = home
  }

  /// Convenience initializer — no field-capture bar. Existing callers compile unchanged.
  public init(
    initialURL: URL? = nil,
    searchURL: @escaping (String) -> URL? = WebAddress.duckDuckGo,
    onNavigate: @escaping (URL) -> Void = { _ in },
    @ViewBuilder accessory: @escaping (WebPage) -> Accessory,
    @ViewBuilder home: @escaping (_ open: @escaping (URL) -> Void) -> Home
  ) where FieldBar == EmptyView {
    self.initialURL = initialURL
    self.searchURL = searchURL
    self.onNavigate = onNavigate
    self.accessory = accessory
    self.fieldBar = { _ in EmptyView() }
    self.home = home
  }

  public var body: some View {
    VStack(spacing: 0) {
      addressBar
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)

      if page.isLoading {
        ProgressView(value: page.estimatedProgress, total: 1)
          .progressViewStyle(.linear)
          .frame(height: 2)
      }

      ZStack {
        WebView(page)
          .ignoresSafeArea(edges: .bottom)
          .opacity(isHome ? 0 : 1)
        if isHome {
          home(open)
        }
      }

      // Field-capture bar: full-width, only shown over a loaded page (not on the home
      // surface). The host returns EmptyView when it supplies no bar.
      if !isHome {
        fieldBar(page)
          .background(.bar)
      }

      Divider()
      bottomBar
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
    .task {
      // Land a fresh session on the host's start page — but never override a page the
      // held session already has (Jon: "unless there is already a URL value there").
      if page.url == nil, let initialURL {
        showingHome = false
        await drive(page.load(URLRequest(url: initialURL)))
      }
    }
  }

  /// The home surface shows before anything loads *and* whenever the home button is
  /// tapped over a loaded page.
  private var isHome: Bool { page.url == nil || showingHome }

  // MARK: Chrome

  private var addressBar: some View {
    HStack(spacing: 8) {
      Image(systemName: page.url?.scheme == "https" ? "lock.fill" : "globe")
        .font(.caption)
        .foregroundStyle(.secondary)
      if editing {
        TextField("Search or enter address", text: $addressText)
          .textContentType(.URL)
          .autocorrectionDisabled()
          .focused($addressFocused)
          .submitLabel(.go)
          .onSubmit(submitAddress)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
          #endif
      } else {
        Text(displayAddress)
          .lineLimit(1)
          .foregroundStyle(page.url == nil ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture(perform: beginEditing)
      }
    }
    .font(.callout)
  }

  private var bottomBar: some View {
    HStack(spacing: 24) {
      Button(action: goBack) {
        Image(systemName: "chevron.backward")
      }
      .disabled(page.backForwardList.backList.isEmpty)

      Button(action: goForward) {
        Image(systemName: "chevron.forward")
      }
      .disabled(page.backForwardList.forwardList.isEmpty)

      if page.isLoading {
        Button(action: page.stopLoading) {
          Image(systemName: "xmark")
        }
      } else {
        Button(action: reload) {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(page.url == nil)
      }

      Button { showingHome = true } label: {
        Image(systemName: "house")
      }
      .disabled(isHome)

      Spacer()
      accessory(page)
    }
    .font(.title3)
    .buttonStyle(.plain)
  }

  // MARK: Navigation

  private var displayAddress: String {
    guard let url = page.url else { return "Search or enter address" }
    return url.host() ?? url.absoluteString
  }

  private func beginEditing() {
    addressText = page.url?.absoluteString ?? ""
    editing = true
    addressFocused = true
  }

  private func submitAddress() {
    editing = false
    addressFocused = false
    guard let url = WebAddress.resolve(addressText, search: searchURL) else { return }
    open(url)
  }

  /// Record (recents) and navigate. The single explicit-navigation path: address-bar
  /// submit and the `home` slot's `open` both land here.
  private func open(_ url: URL) {
    showingHome = false
    onNavigate(url)
    Task { @MainActor in await drive(page.load(URLRequest(url: url))) }
  }

  private func goBack() {
    guard let item = page.backForwardList.backList.last else { return }
    Task { @MainActor in await drive(page.load(item)) }
  }

  private func goForward() {
    guard let item = page.backForwardList.forwardList.first else { return }
    Task { @MainActor in await drive(page.load(item)) }
  }

  private func reload() {
    Task { @MainActor in await drive(page.reload()) }
  }

  /// Iterate a `WebPage` navigation event stream to completion, on the main actor where
  /// the stream's conformance lives. Best-effort — the chrome reflects state via the
  /// observable `isLoading` / `url` / `estimatedProgress`, not the thrown error.
  @MainActor private func drive(_ events: some AsyncSequence) async {
    do {
      for try await _ in events {}
    } catch {}
  }
}
