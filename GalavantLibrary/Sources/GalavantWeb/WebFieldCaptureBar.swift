import SwiftUI
import WebKit

// `GalavantWeb` targets both iOS and macOS (the package host for `swift build`), so
// avoid UIKit/AppKit color inits here — use SwiftUI's platform-agnostic alternatives.

/// A horizontal scrolling row of field chips for the persistent browser's tap-to-fill
/// capture bar (ADR-0025 §5). App-agnostic — it knows how to render chips and
/// retrieve the on-page text selection; the host supplies the field set and what
/// each fill does.
///
/// UX: the user long-presses to select text on the page, then taps a chip. The chip
/// grabs the current selection via `page.currentSelection()` and calls `field.fill`
/// if it is non-empty. Tapping with no selection is a silent no-op. Chips are always
/// enabled (there is no reactive selection binding in the SDK — selection is read
/// imperatively at tap time).
public struct WebFieldCaptureBar: View {
  let page: WebPage
  let fields: [WebCaptureField]
  let onClear: (() -> Void)?

  public init(page: WebPage, fields: [WebCaptureField], onClear: (() -> Void)? = nil) {
    self.page = page
    self.fields = fields
    self.onClear = onClear
  }

  public var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(fields) { field in
          chip(for: field)
        }
        if let onClear { Divider().frame(height: 20); Button(action: onClear){ Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal)
    }
    .padding(.vertical, 6)
  }

  private func chip(for field: WebCaptureField) -> some View {
    Button {
      Task { @MainActor in
        let selection = await page.currentSelection()
        guard !selection.isEmpty else { return }
        field.fill(selection)
      }
    } label: {
      Label(field.label, systemImage: field.systemImage)
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          field.isFilled
            ? Color.accentColor.opacity(0.15)
            : Color.secondary.opacity(0.15)
        )
        .foregroundStyle(field.isFilled ? Color.accentColor : Color.primary)
        .clipShape(.capsule)
    }
    .buttonStyle(.plain)
  }
}
