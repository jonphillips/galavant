import GalavantPlaces
import GalavantSchema
import SwiftUI

/// The trip "romance" header picker (ADR-0032): a searchable Unsplash grid. Seeded
/// from the trip (region/name), the query is editable; tapping a photo pings the ToS
/// tracked-download endpoint and persists the reference onto the trip, then dismisses.
/// A "Remove current photo" row clears it. The `TripHeaderPicker` model (in
/// GalavantPlaces) owns the search/select logic; this is the thin sheet over it.
struct TripHeaderPickerSheet: View {
  @State private var picker: TripHeaderPicker
  /// Whether the trip currently has a header (drives the "Remove" affordance).
  let hasHeader: Bool
  let onChange: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    tripID: Trip.ID,
    tripName: String,
    primaryRegionName: String?,
    hasHeader: Bool,
    onChange: @escaping () -> Void = {}
  ) {
    _picker = State(
      wrappedValue: TripHeaderPicker(
        tripID: tripID, tripName: tripName, primaryRegionName: primaryRegionName
      )
    )
    self.hasHeader = hasHeader
    self.onChange = onChange
  }

  private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(picker.results) { photo in
            cell(photo)
          }
        }
        .padding(8)
      }
      .overlay { statusOverlay }
      .navigationTitle("Header Photo")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $picker.query, prompt: "Search Unsplash")
      .onSubmit(of: .search) { Task { await picker.search() } }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        if hasHeader {
          ToolbarItem(placement: .destructiveAction) {
            Button("Remove", role: .destructive) {
              Task {
                await picker.clear()
                onChange()
                dismiss()
              }
            }
          }
        }
      }
      .task {
        // Auto-run the seeded query on open so the grid isn't empty.
        if picker.results.isEmpty { await picker.search() }
      }
    }
  }

  private func cell(_ photo: UnsplashPhoto) -> some View {
    Button {
      Task {
        await picker.choose(photo)
        onChange()
        dismiss()
      }
    } label: {
      AsyncImage(url: URL(string: photo.thumbURL)) { phase in
        switch phase {
        case .success(let img): img.resizable().scaledToFill()
        default: (photo.color.flatMap(Color.init(hex:)) ?? Color(.secondarySystemBackground))
        }
      }
      .frame(height: 110)
      .frame(maxWidth: .infinity)
      .clipped()
      .clipShape(.rect(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      photo.photographerName.isEmpty ? "Unsplash photo" : "Photo by \(photo.photographerName)"
    )
  }

  @ViewBuilder private var statusOverlay: some View {
    switch picker.phase {
    case .searching:
      ProgressView()
    case .failed:
      ContentUnavailableView {
        Label("Couldn't load photos", systemImage: "wifi.exclamationmark")
      } description: {
        Text("Check your connection and try the search again.")
      }
    case .loaded where picker.results.isEmpty:
      ContentUnavailableView.search
    default:
      EmptyView()
    }
  }
}
