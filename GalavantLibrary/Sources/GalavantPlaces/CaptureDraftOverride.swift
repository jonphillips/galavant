import Foundation
import GalavantSchema

/// Explicit field values set by the browser's tap-to-fill chip bar (ADR-0025 §5),
/// carried into `CaptureModel` before `prepare()` runs. Applied at the end of
/// `prepare()` so user-selected text wins over auto-parsed values for those fields.
///
/// `openingHours` is handled separately in `CaptureModel.persistCapture()` (it flows
/// through a different path than the editable draft), so `apply(to:)` omits it.
public struct CaptureDraftOverride: Sendable {
  public var name: String?
  public var address: String?
  public var notes: String?
  public var openingHours: String?

  public init(
    name: String? = nil,
    address: String? = nil,
    notes: String? = nil,
    openingHours: String? = nil
  ) {
    self.name = name
    self.address = address
    self.notes = notes
    self.openingHours = openingHours
  }

  /// Apply non-nil, non-empty overrides to the draft. Explicit selection wins over the
  /// auto-parser. `openingHours` is handled in `persistCapture()`, not here.
  public func apply(to draft: inout Idea.Draft) {
    if let n = name, !n.isEmpty { draft.name = n }
    if let a = address, !a.isEmpty { draft.address = a }
    if let n = notes, !n.isEmpty { draft.notes = n }
  }
}
