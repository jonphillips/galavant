import SwiftUI

/// House form rule (jon-platform `docs/ios/swiftui-forms.md`): editable fields carry
/// a stable, visible label *above* the control — never placeholder/inline-title only,
/// so the field's identity survives once it has data. These are the app-local helpers
/// the doc prescribes; Galavant's label typography is a subdued caption.
struct StackedFormField<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}

/// A labelled single-line (or growing) text field — the boring common case.
struct StackedTextField: View {
  let title: LocalizedStringKey
  @Binding var text: String
  var prompt: LocalizedStringKey?
  var axis: Axis = .horizontal

  var body: some View {
    StackedFormField(title: title) {
      if let prompt {
        TextField(title, text: $text, prompt: Text(prompt), axis: axis)
      } else {
        TextField(title, text: $text, axis: axis)
      }
    }
  }
}

/// A labelled long-form editor. `TextEditor` has no built-in label, so the title is
/// also wired as its accessibility label.
struct StackedTextEditor: View {
  let title: LocalizedStringKey
  @Binding var text: String
  var minHeight: CGFloat

  var body: some View {
    StackedFormField(title: title) {
      TextEditor(text: $text)
        .frame(minHeight: minHeight)
        .accessibilityLabel(title)
    }
  }
}
