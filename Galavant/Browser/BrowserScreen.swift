import GalavantCaptureUI
import GalavantPlaces
import GalavantWeb
import SwiftUI

/// The top-level **Browser** section (ADR-0023): ADR-0022's deferred "browse to any
/// place, tap capture" entry point. A launcher — an address/search field over recent
/// destinations — opens the app-agnostic `WebExtractorBrowser` modally; "Capture" grabs
/// the rendered DOM and hands it to the *same* capture confirm sheet the share extension
/// uses, so capture-from-browser inherits vet-at-source and the ADR-0019 dedup banner.
///
/// No `NavigationStack` of its own — the `AppContainer` detail/tab column already
/// provides one (nesting another traps the iPad split view; see the nested-stack note).
struct BrowserScreen: View {
  @State private var model = BrowserScreenModel()

  var body: some View {
    Form {
      Section {
        TextField("Search or enter address", text: $model.address)
          .textContentType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { model.go() }
        Button {
          model.go()
        } label: {
          Label("Open browser", systemImage: "arrow.up.right.square")
        }
        .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
      } footer: {
        Text("Browse to a place, then tap Capture to add it to your pool.")
      }

      if !model.recents.isEmpty {
        Section("Recent") {
          ForEach(model.recents, id: \.self) { url in
            Button {
              model.open(url)
            } label: {
              Text(url.host() ?? url.absoluteString)
                .lineLimit(1)
                .foregroundStyle(.primary)
            }
          }
        }
      }
    }
    .navigationTitle("Browser")
    .sheet(
      isPresented: Binding(
        get: { model.browseURL != nil },
        set: { if !$0 { model.browseURL = nil } }
      ),
      onDismiss: { model.browserDismissed() }
    ) {
      if let url = model.browseURL {
        WebExtractorBrowser(startURL: url, title: "Browser", confirmLabel: "Capture") {
          html, sourceURL in
          model.captured(html: html, sourceURL: sourceURL)
        }
      }
    }
    .sheet(item: $model.capture) { payload in
      CaptureConfirmView(
        model: CaptureModel(html: payload.html, sourceURL: payload.sourceURL)
      ) {
        model.captureFinished()
      }
    }
  }
}
