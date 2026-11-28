import SwiftUI
import WebExtractorKit

struct BookingSourceButton: View {
  let url: URL
  @State private var isPresented = false

  var body: some View {
    Button("Source") { isPresented = true }
      .sheet(isPresented: $isPresented) {
        WebExtractorBrowser(startURL: url, title: "Booking source", confirmLabel: "Done") { _, _ in .extracted }
      }
  }
}
