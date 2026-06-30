import Foundation

/// A domain-free descriptor for one chip in the field-capture bar (ADR-0025 §5).
///
/// The host (Galavant, or a future Yes Chef) supplies an array of these to
/// `WebFieldCaptureBar`. `GalavantWeb` only knows the label/icon to render and
/// the `fill` closure to call when the user taps the chip — it never sees what
/// the closure writes to.
///
/// `isFilled` is computed by the host from its own draft state and passed in
/// each time the host rebuilds the array. The bar renders it as a visual cue
/// (tinted chip) but never owns or mutates it.
public struct WebCaptureField: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let systemImage: String
  /// `true` when the host has already filled this field from a prior selection.
  /// Rendered as a tinted chip so the user can see what they've pre-filled.
  public let isFilled: Bool
  /// Called on the main actor with the current on-page selection when the chip
  /// is tapped. Never called with an empty string.
  public let fill: @MainActor @Sendable (String) -> Void

  public init(
    id: String,
    label: String,
    systemImage: String,
    isFilled: Bool = false,
    fill: @escaping @MainActor @Sendable (String) -> Void
  ) {
    self.id = id
    self.label = label
    self.systemImage = systemImage
    self.isFilled = isFilled
    self.fill = fill
  }
}
