import Foundation

/// The travel guides whose judgments the recognizers know how to read — one shared
/// definition of "a guide," keyed by lowercased host fragment (matched with
/// `host.contains`, so `guide.michelin.com` and `michelin.com` both hit).
///
/// Two recognizers consume this table: `EvaluationRecognizers` (reading a rating off
/// the page in hand) and `GuideLinkRecognizer` (deciding whether an outbound link is
/// worth following). Sharing it means the host fragments and the `name` they map to —
/// which doubles as the `IdeaEvaluation.sourceName` stamped for that guide — can never
/// drift between the two. Adding a guide is a one-line edit that lights up both
/// recognition and link-following.
enum GuideHosts {
  struct Guide: Equatable {
    /// Lowercased host fragments that identify this guide (any match wins).
    var fragments: [String]
    /// The guide's display name — also the `IdeaEvaluation.sourceName` for its ratings.
    var name: String
    /// Path segments that mark a *place-detail* page on this guide, where we know the
    /// guide's stable URL scheme (e.g. Michelin's `/restaurant/`, `/hotel/`). Empty
    /// when we only know the host — `GuideLinkRecognizer` then falls back to its
    /// generic depth+slug shape test.
    var detailPathMarkers: [String] = []
  }

  static let michelin = Guide(
    fragments: ["michelin"], name: "Michelin Guide",
    detailPathMarkers: ["restaurant", "hotel"]
  )
  static let andrewHarper = Guide(fragments: ["andrewharper"], name: "Andrew Harper")
  static let forbes = Guide(fragments: ["forbestravelguide"], name: "Forbes Travel Guide")
  static let fiftyBest = Guide(fragments: ["theworlds50best", "50best"], name: "World's 50 Best")

  static let all = [michelin, andrewHarper, forbes, fiftyBest]

  /// The guide whose host fragment matches, if any.
  static func guide(forHost host: String?) -> Guide? {
    guard let host = host?.lowercased() else { return nil }
    return all.first { guide in guide.fragments.contains { host.contains($0) } }
  }
}
