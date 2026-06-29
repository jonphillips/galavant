import SwiftUI
import WebKit

/// An app-agnostic, **persistent** in-app browser with full chrome (ADR-0025): an
/// editable address/search bar, back / forward / refresh / stop, a progress bar, and a
/// `WebView` over a long-lived `WebPage`. It renders sites at **desktop** width (the
/// panel is wide; the desktop layout is richer for capture) and holds a real session, so
/// a login to a paywalled source persists across launches via the default data store.
///
/// It knows no app domain. The host plugs in two slots:
/// - `accessory`: bottom-bar affordances built over the live `WebPage` — the "Capture"
///   action today, a field-capture bar later. The host reads the rendered DOM with
///   `page.currentDOM()`.
/// - `home`: a start surface shown when nothing is loaded yet (e.g. recent destinations);
///   it navigates by calling the supplied `open`.
///
/// `onNavigate` fires on every *explicit* navigation (address-bar submit or a `home`
/// `open`), so the host can record recents without the module knowing what a "recent" is.
/// That one-way seam is what lets the whole browser drop into another app unchanged.
public struct WebBrowserView<Accessory: View, Home: View>: View {
  private let searchURL: (String) -> URL?
  private let onNavigate: (URL) -> Void
  private let accessory: (WebPage) -> Accessory
  private let home: (@escaping (URL) -> Void) -> Home

  @State private var page = WebPage.browser(contentMode: .desktop)
  @State private var addressText = ""
  @State private var editing = false
  @FocusState private var addressFocused: Bool

  public init(
    searchURL: @escaping (String) -> URL? = WebAddress.duckDuckGo,
    onNavigate: @escaping (URL) -> Void = { _ in },
    @ViewBuilder accessory: @escaping (WebPage) -> Accessory,
    @ViewBuilder home: @escaping (_ open: @escaping (URL) -> Void) -> Home
  ) {
    self.searchURL = searchURL
    self.onNavigate = onNavigate
    self.accessory = accessory
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
          .opacity(page.url == nil ? 0 : 1)
        if page.url == nil {
          home(open)
        }
      }

      Divider()
      bottomBar
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
  }

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
