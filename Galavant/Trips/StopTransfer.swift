import CoreTransferable
import GalavantSchema
import UniformTypeIdentifiers

extension UTType {
  /// A Galavant itinerary stop being dragged between days / the bucket. Declared
  /// in the app's `Info.plist` (`UTExportedTypeDeclarations`) so same-app drags
  /// carry a typed payload rather than ambiguous text. App-private — nothing else
  /// reads or writes it.
  static let galavantTripStop = UTType(exportedAs: "com.jonphillips.galavant.trip-stop")
}

/// The payload of a dragged itinerary stop: just the `TripIdea` row id, resolved
/// back to its entry by the model on drop (`moveStop`/`moveStopToBeScheduled`).
/// Typed (its own `UTType`) so a day section only accepts a stop, not stray text.
struct StopTransfer: Codable, Transferable {
  let stopID: TripIdea.ID

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .galavantTripStop)
  }
}
