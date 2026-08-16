import GalavantSchema
import SwiftUI
import UIKit

/// The Journey surface's upper-right image band (M10). It fills the header row's
/// otherwise-empty right side — never the map's column — and its content follows
/// the current selection:
///
/// - **A stay is selected** → the stay's region "romance" photo beside the hotel's
///   header image.
/// - **A day is selected** → that day's stops, dinner first (a located meal reads
///   as the day's anchor image).
/// - **Nothing selected** → the trip's opening region photo, an ambient hero.
///
/// Tapping the region card opens the dual-source picker (Unsplash / Photos). All
/// imagery is the thumbnail tier — bounded memory across a growing photo library;
/// display-on-demand is a later refinement if the heroes want more resolution.
struct JourneyImagePanel: View {
  let projection: JourneyProjection
  let plan: TripPlan
  let model: JourneyModel
  let selection: JourneySelection?

  @State private var pickerRegion: MapRegion?

  private static let cardHeight: CGFloat = 132

  var body: some View {
    content
      .frame(height: Self.cardHeight)
      .sheet(item: $pickerRegion) { region in
        RegionPhotoPickerSheet(
          regionID: region.id,
          regionName: region.name,
          hasPhoto: model.regionThumbnail(forRegion: region.id) != nil)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch selection {
    case .day(let dayNumber):
      dayImages(dayNumber)
    case .stay(let id):
      stayImages(id)
    case .none:
      if let region = focusedRegion {
        regionCard(region)
          .frame(maxWidth: 260)
      } else {
        EmptyView()
      }
    }
  }

  // MARK: Stay — region + hotel

  @ViewBuilder
  private func stayImages(_ id: TripStay.ID) -> some View {
    if let band = projection.stayBands.first(where: { $0.id == id }) {
      HStack(spacing: 12) {
        if let region = region(forStay: band) {
          regionCard(region)
            .frame(maxWidth: 240)
        }
        JourneyImageCard(
          thumbnail: model.thumbnail(forIdea: band.stay.idea?.id),
          title: band.title,
          subtitle: "Where you'll stay",
          systemFallback: Icon.stay.systemName)
        .frame(maxWidth: 240)
      }
    }
  }

  // MARK: Day — stops, dinner first

  @ViewBuilder
  private func dayImages(_ dayNumber: Int) -> some View {
    let stops = orderedStops(forDay: dayNumber)
    if stops.isEmpty {
      if let region = region(forDay: dayNumber) {
        regionCard(region).frame(maxWidth: 260)
      }
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(stops) { stop in
            JourneyImageCard(
              thumbnail: model.thumbnail(forIdea: stop.ideaID),
              title: stop.title,
              subtitle: stop.kind == .food ? "Dinner" : stop.kind?.label,
              systemFallback: stop.kind?.systemImage ?? "mappin.and.ellipse")
            .frame(width: 200)
          }
        }
        .padding(.trailing, 4)
      }
    }
  }

  /// A day's stops with a header image, dinner (a `.food` stop) floated to the
  /// front so the day's meal reads as its anchor image, then itinerary order.
  private func orderedStops(forDay dayNumber: Int) -> [JourneyProjection.StopDigest] {
    let stops = projection.days.first { $0.dayNumber == dayNumber }?.stops ?? []
    let withImages = stops.filter { model.thumbnail(forIdea: $0.ideaID) != nil }
    let dinner = withImages.filter { $0.kind == .food }
    let rest = withImages.filter { $0.kind != .food }
    return dinner + rest
  }

  // MARK: Region card

  private func regionCard(_ region: MapRegion) -> some View {
    JourneyImageCard(
      thumbnail: model.regionThumbnail(forRegion: region.id),
      title: region.name,
      subtitle: nil,
      systemFallback: "photo",
      attribution: model.regionAttribution(forRegion: region.id),
      placeholderPrompt: "Add region photo",
      onTap: { pickerRegion = region })
  }

  private var focusedRegion: MapRegion? {
    projection.days.first.map { region(forDay: $0.dayNumber) } ?? nil
  }

  /// A day's region: its explicit `TripDayRegion` assignment when set, else a saved
  /// region that geographically covers the day's first located stop.
  private func region(forDay dayNumber: Int) -> MapRegion? {
    if let assigned = plan.region(forDay: dayNumber) { return assigned }
    let stop = plan.locatedStops(forDay: dayNumber).first
    return model.region(containingLatitude: stop?.content.latitude, longitude: stop?.content.longitude)
  }

  /// A stay's region: the region assigned to its first day, else a saved region
  /// covering the stay's own coordinate.
  private func region(forStay band: JourneyProjection.StayBand) -> MapRegion? {
    if let assigned = plan.region(forDay: band.nights.lowerBound) { return assigned }
    return model.region(
      containingLatitude: band.stay.content.latitude, longitude: band.stay.content.longitude)
  }
}

/// One image card in the panel: a fill-style thumbnail with a bottom gradient scrim
/// and title, an SF-symbol placeholder when there's no image, and an optional
/// Unsplash attribution caption. Tappable region cards carry an "add photo" prompt.
struct JourneyImageCard: View {
  let thumbnail: Data?
  let title: String
  var subtitle: String?
  let systemFallback: String
  var attribution: (name: String, username: String?)?
  var placeholderPrompt: String?
  var onTap: (() -> Void)?

  var body: some View {
    Group {
      if let onTap {
        Button(action: onTap) { card }.buttonStyle(.plain)
      } else {
        card
      }
    }
  }

  private var card: some View {
    ZStack(alignment: .bottomLeading) {
      image
      LinearGradient(
        colors: [.clear, .black.opacity(0.55)],
        startPoint: .center, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 1) {
        if let subtitle {
          Text(subtitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(2)
      }
      .shadow(color: .black.opacity(0.5), radius: 2)
      .padding(10)
      if let attribution { attributionCaption(attribution) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(subtitle.map { "\($0), \(title)" } ?? title)
  }

  @ViewBuilder
  private var image: some View {
    if let thumbnail, let uiImage = UIImage(data: thumbnail) {
      Image(uiImage: uiImage)
        .resizable()
        .scaledToFill()
    } else {
      ZStack {
        Color(.secondarySystemBackground)
        VStack(spacing: 6) {
          Image(systemName: onTap != nil ? "photo.badge.plus" : systemFallback)
            .font(.title2)
            .foregroundStyle(.secondary)
          if let placeholderPrompt, onTap != nil {
            Text(placeholderPrompt)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  /// "Photo by {name} on Unsplash" — the ToS attribution, tiny and unobtrusive,
  /// as UTM-tagged links (runtime strings, so built as an `AttributedString`).
  @ViewBuilder
  private func attributionCaption(_ attribution: (name: String, username: String?)) -> some View {
    if let text = attributionText(attribution) {
      Text(text)
        .font(.system(size: 8))
        .tint(.white)
        .foregroundStyle(.white.opacity(0.85))
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
  }

  private func attributionText(_ attribution: (name: String, username: String?)) -> AttributedString? {
    let photographer: String = {
      guard let username = attribution.username, !username.isEmpty else { return attribution.name }
      return "[\(attribution.name)](https://unsplash.com/@\(username)?utm_source=galavant&utm_medium=referral)"
    }()
    let markdown =
      "Photo by \(photographer) on "
      + "[Unsplash](https://unsplash.com/?utm_source=galavant&utm_medium=referral)"
    return try? AttributedString(markdown: markdown)
  }
}
