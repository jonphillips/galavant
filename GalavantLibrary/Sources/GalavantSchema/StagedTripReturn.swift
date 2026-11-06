import Foundation
import GalavantAI

/// The shared parsing boundary for staged returns and the helper that writes them.
public enum StagedTripReturn {
  public enum Validated: Equatable, Sendable {
    case candidates(token: UUID?, [TripCandidate], note: String?)
    case seed(token: UUID?, SeedReturn)
  }

  public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
    case ambiguousPlaces

    public var errorDescription: String? {
      "For a trip seed, resend with a line containing only GV-SEED before the JSON object. For candidate places, resend them as one JSON array."
    }
  }

  public static func strippingTripLine(from text: String) -> String {
    text.components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("GV-TRIP:") }
      .joined(separator: "\n")
  }

  public static func validate(_ text: String) throws -> Validated {
    let withoutTrip = strippingTripLine(from: text)
    let routed: RoutedText?
    do {
      routed = try HandoffRouting.route(withoutTrip)
    } catch HandoffRoutingError.missingToken {
      routed = nil
    }
    let body = try RecommendationHandoffContract.marker.strippingMarker(from: routed?.text ?? withoutTrip).text
    switch HandoffReturnKind.classify(body) {
    case .candidatePlaces:
      let decoded = try TripCandidate.decodeReturn(body)
      guard decoded.candidates.contains(where: { !$0.suggestedTitle.isEmpty }) else {
        throw TripCandidateDecodeError.emptyCandidates
      }
      return .candidates(token: routed?.sessionID, decoded.candidates, note: decoded.note)
    case .seedTrip:
      let seed = try SeedReturn.decode(body)
      guard !seed.bases.isEmpty || SeedReturn.markerLine(in: body.split(whereSeparator: \.isNewline)) != nil else {
        throw ValidationError.ambiguousPlaces
      }
      return .seed(token: routed?.sessionID, seed)
    }
  }
}
