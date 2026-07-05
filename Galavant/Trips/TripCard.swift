import GalavantSchema
import SwiftUI

/// One trip as a photo-forward card in the Trips collection. The header image
/// (ADR-0032) fills the card as a hero; the name and a certainty/duration line
/// sit over a bottom scrim so they stay legible on any photo. Trips with no
/// header fall back to a seeded gradient (stable per trip) so an empty card
/// still looks intentional rather than blank.
struct TripCard: View {
  let trip: Trip

  private static let height: CGFloat = 190
  private static let corner: CGFloat = 16

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      backdrop
      scrim
      caption
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .clipShape(.rect(cornerRadius: Self.corner))
    .overlay {
      RoundedRectangle(cornerRadius: Self.corner)
        .strokeBorder(.white.opacity(0.08))
    }
    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    .accessibilityElement(children: .combine)
  }

  /// The hero photo (hotlinked via `AsyncImage`), over the seeded gradient that
  /// shows while it loads, offline, or when the trip has no header at all.
  private var backdrop: some View {
    seededGradient
      .overlay {
        if let image = trip.headerImage {
          AsyncImage(url: URL(string: image.url)) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Color.clear
            }
          }
        } else {
          Icon.trips.image
            .font(.system(size: 44))
            .foregroundStyle(.white.opacity(0.28))
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: Self.height)
      .clipped()
  }

  /// Darken the bottom so white text reads over bright photos.
  private var scrim: some View {
    LinearGradient(
      colors: [.clear, .black.opacity(0.6)],
      startPoint: .center,
      endPoint: .bottom
    )
  }

  private var caption: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(trip.name.isEmpty ? "Untitled Trip" : trip.name)
        .font(.headline)
        .lineLimit(2)
      Text("\(trip.certaintySummary) · ^[\(trip.lengthInDays) day](inflect: true)")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.4), radius: 3)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A stable, pleasant gradient derived from the trip name — used as the
  /// loading/offline/no-photo backdrop. Prefers the Unsplash-supplied average
  /// color when a header exists (it matches the incoming photo).
  private var seededGradient: LinearGradient {
    let base = trip.headerImage?.color.flatMap(Color.init(hex:)) ?? seededColor
    return LinearGradient(
      colors: [base.opacity(0.8), base],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var seededColor: Color {
    let seed = trip.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return Color(hue: Double(seed % 360) / 360, saturation: 0.5, brightness: 0.5)
  }
}

extension Trip {
  /// Human-readable commitment level, derived from the domain `Certainty`.
  var certaintySummary: String {
    switch certainty {
    case .someday:
      "Someday"
    case let .targeted(year, quarter):
      if let quarter { "\(quarter.label) \(year)" } else { "\(year)" }
    case let .dated(start):
      start.formatted(date: .abbreviated, time: .omitted)
    }
  }
}
