import Foundation
import GalavantAI

/// The shared parsing boundary for staged returns and the helper that writes them.
public enum StagedTripReturn {
  public enum Validated: Equatable, Sendable {
    case candidates(token: UUID?, [TripCandidate], note: String?)
    case seed(token: UUID?, SeedReturn)
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
      return .seed(token: routed?.sessionID, try SeedReturn.decode(body))
    }
  }
}
