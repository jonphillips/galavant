import SwiftUI

/// Temporary, clearly labeled spike for judging the raw `MapFeature.image` value.
/// Keep this separate from Apple's native place detail; it is intentionally easy to
/// remove if the feature image is only a glyph or otherwise not useful to Galavant.
struct MapFeatureImageSpikeView: View {
  let image: Image

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("MapFeature image spike", systemImage: "photo")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      image
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: 180)
        .clipShape(.rect(cornerRadius: 12))
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }
}
