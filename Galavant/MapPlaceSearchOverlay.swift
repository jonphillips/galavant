import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

struct MapPlaceSearchOverlay: View {
  let viewport: PlaceSearchViewport?
  /// When non-empty, the search is scoped to these regions rather than the camera
  /// viewport.
  let searchRegions: [MapRegion]
  let biased: Bool
  let seedQuery: String?
  let onSelect: (Place) async -> Void

  @State private var search: PlaceSearchModel
  @FocusState private var searchFieldFocused: Bool

  init(
    visibleRegion: MKCoordinateRegion?,
    searchRegions: [MapRegion] = [],
    biased: Bool = false,
    seedQuery: String? = nil,
    onSelect: @escaping (Place) async -> Void
  ) {
    let viewport = visibleRegion.map(PlaceSearchViewport.init(region:))
    self.viewport = viewport
    self.searchRegions = searchRegions
    self.biased = biased
    self.seedQuery = seedQuery
    self.onSelect = onSelect
    _search = State(
      initialValue: searchRegions.isEmpty
        ? PlaceSearchModel(viewport: viewport)
        : PlaceSearchModel(regions: searchRegions, biased: biased)
    )
  }

  var body: some View {
    @Bindable var search = search
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search this map", text: $search.query)
          .textInputAutocapitalization(.words)
          .submitLabel(.search)
          .focused($searchFieldFocused)
          .onSubmit {
            guard let firstResult = search.results.first else { return }
            Task { await resultTapped(firstResult) }
          }
        if !search.query.isEmpty {
          Button {
            search.cancelButtonTapped()
            searchFieldFocused = false
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear map search")
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)

      if !search.results.isEmpty {
        Divider()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(search.results) { place in
              Button {
                Task { await resultTapped(place) }
              } label: {
                MapPlaceSearchResultRow(
                  // Rural MapKit hits often carry no city or address, so several
                  // same-named results (a lake, a hotel, an alm all called
                  // "Lautersee") would render identically. Fall back to the kind
                  // label so the icon isn't the only thing telling them apart.
                  name: place.name,
                  subtitle: place.subtitle.isEmpty ? (place.kind?.label ?? "") : place.subtitle,
                  systemImage: place.kind?.systemImage ?? "mappin"
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxHeight: 280)
      }
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    .frame(maxWidth: 460)
    .padding(.horizontal, 12)
    .padding(.top, 8)
    // Camera moves only re-scope fields that use the viewport. When the caller supplies
    // trip regions, panning must not drag the scope back to the pinhole box.
    .onChange(of: viewport, initial: true) { _, viewport in
      guard searchRegions.isEmpty else { return }
      search.visibleRegionChanged(viewport)
    }
    // Re-scope when the caller's region bias changes. The model preserves whether this
    // scope is biased.
    .onChange(of: searchRegions, initial: true) { _, regions in
      search.regionsChanged(regions)
    }
    // Prefill the field with the caller's current subject (e.g. the focused
    // candidate's name) so finding it on the map is one tap, not re-typing — the
    // same "search is seeded from what you're looking at" move the browser makes.
    // Only re-seeds when the subject itself changes, so it never clobbers typing.
    .onChange(of: seedQuery, initial: true) { _, newValue in
      guard let newValue, !newValue.isEmpty else { return }
      search.query = newValue
    }
  }

  private func resultTapped(_ place: Place) async {
    await onSelect(place)
    guard !Task.isCancelled else { return }
    search.resultTapped()
    searchFieldFocused = false
  }
}

private struct MapPlaceSearchResultRow: View {
  let name: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .foregroundStyle(.primary)
          .lineLimit(1)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}
