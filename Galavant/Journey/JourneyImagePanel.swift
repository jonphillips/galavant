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
/// Tapping the region card opens the dual-source picker (Unsplash / Photos). Thumbnails
/// appear immediately, then the model replaces only the current panel's cards with
/// display-tier images.
struct JourneyImagePanel: View {
  let projection: JourneyProjection
  let plan: TripPlan
  let model: JourneyModel
  let selection: JourneySelection?

  @State private var pickerRegion: MapRegion?

  /// A taller hero band makes the image treatment feel intentional beside the
  /// trip summary while leaving the shared Journey section gap visible below.
  private static let cardHeight: CGFloat = 168
  private static let cardSpacing: CGFloat = 12
  /// Three cards need three readable surfaces plus two existing gaps. Below this
  /// width, the panel stays at two cards rather than making each hero too narrow.
  private static let minimumThreeCardWidth: CGFloat = 444

  var body: some View {
    let request = model.displayRequest(projection: projection, plan: plan, selection: selection)
    return GeometryReader { geometry in
      content(width: geometry.size.width)
    }
      .frame(height: Self.cardHeight)
      .clipped()
      .task(id: request) { await model.loadDisplayImages(request) }
      .sheet(item: $pickerRegion) { region in
        RegionPhotoPickerSheet(
          regionID: region.id,
          regionName: region.name,
          hasPhoto: model.regionThumbnail(forRegion: region.id) != nil)
      }
  }

  @ViewBuilder
  private func content(width: CGFloat) -> some View {
    switch selection {
    case .day(let dayNumber):
      dayImages(dayNumber, width: width)
    case .stay(let id):
      stayImages(id, width: width)
    case .none:
      if let region = focusedRegion {
        regionCard(region, width: width)
      } else {
        EmptyView()
      }
    }
  }

  // MARK: Stay — region + hotel

  @ViewBuilder
  private func stayImages(_ id: TripStay.ID, width: CGFloat) -> some View {
    if let band = projection.stayBands.first(where: { $0.id == id }) {
      let region = region(forStay: band)
      let legStop = JourneyImageSelection.stableStayStop(
        stayID: band.id,
        nights: band.nights,
        days: projection.days,
        hasImage: { model.thumbnail(forIdea: $0) != nil })
      let showThirdCard = width >= Self.minimumThreeCardWidth && region != nil && legStop != nil
      let cardCount = (region == nil ? 0 : 1) + 1 + (showThirdCard ? 1 : 0)
      let cardWidth = Self.cardWidth(for: width, count: cardCount)
      HStack(spacing: Self.cardSpacing) {
        if let region {
          regionCard(region, width: cardWidth)
        }
        JourneyImageCard(
          thumbnail: model.thumbnail(forIdea: band.stay.idea?.id),
          displayImage: model.displayImage(forIdea: band.stay.idea?.id),
          title: band.title,
          subtitle: "Where you'll stay",
          systemFallback: Icon.stay.systemName)
        .frame(width: cardWidth, height: Self.cardHeight)
        if showThirdCard, let legStop {
          JourneyImageCard(
            thumbnail: model.thumbnail(forIdea: legStop.ideaID),
            displayImage: model.displayImage(forIdea: legStop.ideaID),
            title: legStop.title,
            subtitle: legStop.kind?.label,
            systemFallback: legStop.kind?.systemImage ?? "mappin.and.ellipse")
            .frame(width: cardWidth, height: Self.cardHeight)
        }
      }
      .frame(width: width, alignment: .leading)
    }
  }

  // MARK: Day — stops, dinner first

  @ViewBuilder
  private func dayImages(_ dayNumber: Int, width: CGFloat) -> some View {
    let stops = orderedStops(forDay: dayNumber)
    if stops.isEmpty {
      if let region = region(forDay: dayNumber) {
        regionCard(region, width: width)
      }
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Self.cardSpacing) {
          ForEach(stops) { stop in
            JourneyImageCard(
              thumbnail: model.thumbnail(forIdea: stop.ideaID),
              displayImage: model.displayImage(forIdea: stop.ideaID),
              title: stop.title,
              subtitle: stop.kind == .food ? "Dinner" : stop.kind?.label,
              systemFallback: stop.kind?.systemImage ?? "mappin.and.ellipse")
            .frame(width: 200, height: Self.cardHeight)
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

  private func regionCard(_ region: MapRegion, width: CGFloat) -> some View {
    JourneyImageCard(
      thumbnail: model.regionThumbnail(forRegion: region.id),
      displayImage: model.displayImage(forRegion: region.id),
      title: region.name,
      subtitle: nil,
      systemFallback: "photo",
      attribution: model.regionAttribution(forRegion: region.id),
      placeholderPrompt: "Add region photo",
      onTap: { pickerRegion = region })
      .frame(width: width, height: Self.cardHeight)
  }

  private static func cardWidth(for width: CGFloat, count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    let gaps = CGFloat(max(0, count - 1)) * cardSpacing
    return max(0, (width - gaps) / CGFloat(count))
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

/// One image card in the panel: a fill-style image with a bottom gradient scrim
/// and title, an SF-symbol placeholder when there's no image, and an optional
/// Unsplash attribution caption. Tappable region cards carry an "add photo" prompt.
struct JourneyImageCard: View {
  let thumbnail: Data?
  var displayImage: UIImage?
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
    if let displayImage {
      JourneyAspectFillImage(image: displayImage, focalPoint: .center)
    } else if let thumbnail, let uiImage = UIImage(data: thumbnail) {
      JourneyAspectFillImage(image: uiImage, focalPoint: .center)
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

/// Places an image at its aspect-fill size, then applies a bounded crop inside
/// the card. SwiftUI's `scaledToFill()` is correct for simple cases, but this
/// explicit placement prevents an image's intrinsic size from escaping the
/// card when the parent is measured through a `GeometryReader` and gives us a
/// focal point for future per-photo tuning.
private struct JourneyAspectFillImage: View {
  let image: UIImage
  let focalPoint: UnitPoint

  var body: some View {
    GeometryReader { geometry in
      let placement = JourneyAspectFillPlacement(
        sourceSize: image.size,
        containerSize: geometry.size,
        focalPoint: focalPoint)

      Image(uiImage: image)
        .resizable()
        .frame(width: placement.renderedSize.width, height: placement.renderedSize.height)
        .position(x: placement.center.x, y: placement.center.y)
    }
    .clipped()
  }
}

/// Pure aspect-fill geometry. The rendered image always covers the destination
/// rectangle; the origin is shifted only along an overflowing axis, so no image
/// content can hang outside the card and no letterboxing is introduced.
private struct JourneyAspectFillPlacement {
  let renderedSize: CGSize
  let center: CGPoint

  init(sourceSize: CGSize, containerSize: CGSize, focalPoint: UnitPoint) {
    guard sourceSize.width > 0, sourceSize.height > 0,
      containerSize.width > 0, containerSize.height > 0
    else {
      renderedSize = .zero
      center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
      return
    }

    let scale = max(
      containerSize.width / sourceSize.width,
      containerSize.height / sourceSize.height)
    let renderedSize = CGSize(
      width: sourceSize.width * scale,
      height: sourceSize.height * scale)
    let overflow = CGSize(
      width: max(0, renderedSize.width - containerSize.width),
      height: max(0, renderedSize.height - containerSize.height))
    let origin = CGPoint(
      x: -overflow.width * min(max(focalPoint.x, 0), 1),
      y: -overflow.height * min(max(focalPoint.y, 0), 1))

    self.renderedSize = renderedSize
    center = CGPoint(
      x: origin.x + renderedSize.width / 2,
      y: origin.y + renderedSize.height / 2)
  }
}
