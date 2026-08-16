import GalavantPlaces
import GalavantSchema
import PhotosUI
import SwiftUI

/// The region "romance" photo picker (M10): choose from Unsplash **or** your own
/// Photos library, both stored as bytes so one render path serves them. A thin
/// sheet over `RegionPhotoPicker` (which owns search/download/process/store); the
/// app hosts only the grid, the `PhotosPicker`, and the source toggle.
struct RegionPhotoPickerSheet: View {
  @State private var picker: RegionPhotoPicker
  @State private var source: Source = .unsplash
  @State private var photosItem: PhotosPickerItem?
  /// Whether the region currently has a photo (drives the "Remove" affordance).
  let hasPhoto: Bool
  @Environment(\.dismiss) private var dismiss

  enum Source: String, CaseIterable {
    case unsplash = "Unsplash"
    case photos = "My Photos"
  }

  init(regionID: MapRegion.ID, regionName: String, hasPhoto: Bool) {
    _picker = State(wrappedValue: RegionPhotoPicker(regionID: regionID, regionName: regionName))
    self.hasPhoto = hasPhoto
  }

  private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

  var body: some View {
    NavigationStack {
      Group {
        switch source {
        case .unsplash: unsplashGrid
        case .photos: photosPane
        }
      }
      .navigationTitle("Region Photo")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .top) {
        Picker("Source", selection: $source) {
          ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        if hasPhoto {
          ToolbarItem(placement: .destructiveAction) {
            Button("Remove", role: .destructive) {
              Task {
                await picker.clear()
                dismiss()
              }
            }
          }
        }
      }
      .task {
        if source == .unsplash, picker.results.isEmpty { await picker.search() }
      }
    }
  }

  private var unsplashGrid: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(picker.results) { photo in
          cell(photo)
        }
      }
      .padding(8)
    }
    .overlay { statusOverlay }
    .searchable(text: $picker.query, prompt: "Search Unsplash")
    .onSubmit(of: .search) { Task { await picker.search() } }
  }

  private func cell(_ photo: UnsplashPhoto) -> some View {
    Button {
      Task {
        if await picker.choose(photo) { dismiss() }
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
      photo.photographerName.isEmpty ? "Unsplash photo" : "Photo by \(photo.photographerName)")
  }

  private var photosPane: some View {
    VStack(spacing: 16) {
      PhotosPicker(selection: $photosItem, matching: .images) {
        Label("Choose from Photos", systemImage: "photo.on.rectangle")
          .font(.headline)
          .padding(.vertical, 12)
          .padding(.horizontal, 20)
          .background(.tint, in: Capsule())
          .foregroundStyle(.white)
      }
      if case .saving = picker.phase { ProgressView() }
      if case .failed(let message) = picker.phase {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      Text("Your own photo becomes this region's image on the Journey screen.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: photosItem) { _, item in
      guard let item else { return }
      Task {
        if let data = try? await item.loadTransferable(type: Data.self),
          await picker.chooseFromLibrary(data) {
          dismiss()
        }
      }
    }
  }

  @ViewBuilder private var statusOverlay: some View {
    switch picker.phase {
    case .searching, .saving:
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
