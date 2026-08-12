import Foundation

/// Matching helpers kept separate from reconciliation application and history
/// bookkeeping so the main reconciliation policy remains readable.
extension CalendarReconciliation {
  /// Comparison-only normalization: case/diacritic/punctuation differences in a
  /// Calendar title must not make one place appear unmatched. Empty names never
  /// match; they carry no place evidence.
  static func normalizedName(_ name: String) -> String {
    name
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
      .joined()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// A title fragment is not enough: both sides must share a complete, meaningful
  /// token. This avoids raw-substring accidents such as `bar` matching `barcelona`.
  static func sharesMeaningfulNameToken(_ input: CalendarIngestedEvent, stop: ResolvedStop) -> Bool {
    let eventTokens = Set(normalizedName(input.matchedPlace?.name ?? input.event.title).split(separator: " "))
    let stopTokens = Set(normalizedName(stop.content.title).split(separator: " "))
    return eventTokens.intersection(stopTokens).contains { $0.count >= 4 }
  }

  /// A nearby, differently-resolved Maps record is enough to invite review but is
  /// intentionally not enough to create a Calendar binding. Coordinates must exist
  /// on both sides; absent location facts never turn name similarity into evidence.
  static func isNearby(_ input: CalendarIngestedEvent, stop: ResolvedStop) -> Bool {
    guard
      let eventLatitude = input.event.latitude,
      let eventLongitude = input.event.longitude,
      let stopLatitude = stop.content.latitude,
      let stopLongitude = stop.content.longitude
    else { return false }

    return distanceInMeters(
      latitude1: eventLatitude,
      longitude1: eventLongitude,
      latitude2: stopLatitude,
      longitude2: stopLongitude) <= 100
  }

  static func distanceInMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
  ) -> Double {
    let latitudeDelta = (latitude2 - latitude1) * .pi / 180
    let longitudeDelta = (longitude2 - longitude1) * .pi / 180
    let haversine = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
      + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180)
      * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
    return 6_371_000 * 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
  }
}
