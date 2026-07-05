import GalavantSchema
import SwiftUI

/// The trip's "romance" header (ADR-0032): a hotlinked Unsplash photo shown as a
/// hero band at the top of the detail panel so a trip *feels like its place*. Renders
/// from the CDN via `AsyncImage`, falling back to the stored placeholder color while
/// it loads (or offline). Carries the mandatory Unsplash attribution — "Photo by … on
/// Unsplash" — as real, UTM-tagged links, per the API guidelines. The corner button
/// (not the whole band) opens the picker, so the attribution links stay tappable.
struct TripHeaderImageView: View {
  let image: TripHeaderImage
  /// Open the picker to change/remove the header.
  let onChange: () -> Void

  private static let height: CGFloat = 160

  private var placeholder: Color {
    image.color.flatMap(Color.init(hex:)) ?? Color(.secondarySystemBackground)
  }

  var body: some View {
    placeholder
      .overlay {
        AsyncImage(url: URL(string: image.url)) { phase in
          switch phase {
          case .success(let img): img.resizable().scaledToFill()
          default: Color.clear
          }
        }
      }
      .frame(height: Self.height)
      .frame(maxWidth: .infinity)
      .clipped()
      .overlay(alignment: .bottomLeading) { attribution }
      .overlay(alignment: .topTrailing) { changeButton }
      .accessibilityElement(children: .contain)
  }

  /// "Photo by {name} on Unsplash" — real links, UTM-tagged per Unsplash's ToS. Built
  /// as a markdown `AttributedString` (the strings are runtime values, so a plain
  /// `Text` wouldn't parse the links). Only shown when there's a photographer to credit.
  /// Kept as small and unobtrusive as possible (Jon's ask; this is a private app) — a
  /// tiny shadowed caption with no pill, just legible enough over the photo.
  @ViewBuilder private var attribution: some View {
    if let text = attributionText {
      Text(text)
        .font(.system(size: 9))
        .tint(.white)
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(8)
    }
  }

  private var attributionText: AttributedString? {
    guard let name = image.photographerName, !name.isEmpty else { return nil }
    let photographer: String = {
      guard let username = image.photographerUsername, !username.isEmpty else { return name }
      return "[\(name)](https://unsplash.com/@\(username)?utm_source=galavant&utm_medium=referral)"
    }()
    let markdown =
      "Photo by \(photographer) on "
      + "[Unsplash](https://unsplash.com/?utm_source=galavant&utm_medium=referral)"
    return try? AttributedString(markdown: markdown)
  }

  private var changeButton: some View {
    Button(action: onChange) {
      Icon.headerImage.image
        .font(.caption)
        .foregroundStyle(.white)
        .padding(7)
        .background(.black.opacity(0.28), in: .circle)
    }
    .buttonStyle(.plain)
    .padding(8)
    .accessibilityLabel("Change header photo")
  }
}

extension Color {
  /// A `#RRGGBB` (or `RRGGBB`) hex string → `Color`; nil on anything malformed, so a
  /// junk value falls back rather than crashing. Unsplash's `color` field is this shape.
  init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}
