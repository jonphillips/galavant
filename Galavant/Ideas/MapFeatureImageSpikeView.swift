import MapKit
import SwiftUI
import UIKit

/// Temporary, clearly labeled Look Around snapshot spike.
/// Keep this separate from the native place detail; it is intentionally easy to
/// remove after the device review.
struct LookAroundSnapshotSpikeView: View {
  let item: MKMapItem

  private enum LoadState {
    case loading
    case image(UIImage)
    case noCoverage
  }

  @State private var loadState: LoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Look Around snapshot spike", systemImage: "binoculars")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      switch loadState {
      case .loading:
        ProgressView("Loading Look Around…")
          .frame(maxWidth: .infinity, minHeight: 80)
      case let .image(image):
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: 180)
          .clipShape(.rect(cornerRadius: 12))
      case .noCoverage:
        VStack(spacing: 4) {
          Text("No Look Around here")
            .font(.subheadline.weight(.semibold))
          Text("Apple has no Look Around coverage for this place.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .task(id: item.name ?? "\(item.location.coordinate.latitude),\(item.location.coordinate.longitude)") {
      await loadSnapshot()
    }
  }

  @MainActor
  private func loadSnapshot() async {
    loadState = .loading

    let request = MKLookAroundSceneRequest(mapItem: item)
    guard !Task.isCancelled else { return }
    guard let scene = try? await request.scene else {
      loadState = .noCoverage
      return
    }
    guard !Task.isCancelled else { return }

    let options = MKLookAroundSnapshotter.Options()
    options.size = CGSize(width: 600, height: 300)
    guard let snapshot = try? await MKLookAroundSnapshotter(
      scene: scene,
      options: options
    ).snapshot else {
      loadState = .noCoverage
      return
    }
    guard !Task.isCancelled else { return }

    loadState = .image(snapshot.image)
  }
}
