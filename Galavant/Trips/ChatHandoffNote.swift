import SwiftUI

struct ChatHandoffNote: View {
  let note: String
  let isSaved: Bool
  let save: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(note)
        .textSelection(.enabled)
      Button(isSaved ? "Saved" : "Save to Trip Documents", systemImage: isSaved ? "checkmark" : "doc.badge.plus", action: save)
        .disabled(isSaved)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
