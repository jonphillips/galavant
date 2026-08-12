import Foundation

extension Sequence where Element: Identifiable, Element.ID == UUID {
  /// Collapse logical duplicates to one element per `key`, keeping the survivor
  /// with the lowest id. This total, stable order lets every device independently
  /// choose the same winner (ADR-0008 / persistence-and-sync law 3).
  ///
  /// This operation is pure: non-owning read paths consume `survivors` without
  /// mutating, while the owning write path separately deletes `losers`.
  public func convergingByKey<Key: Hashable>(
    _ key: (Element) -> Key
  ) -> (survivors: [Element], losers: [Element]) {
    var survivorIndices: [Key: Int] = [:]
    var survivors: [Element] = []
    var losers: [Element] = []

    for element in self {
      let key = key(element)
      guard let survivorIndex = survivorIndices[key] else {
        survivorIndices[key] = survivors.endIndex
        survivors.append(element)
        continue
      }

      if element.id.uuidString < survivors[survivorIndex].id.uuidString {
        losers.append(survivors[survivorIndex])
        survivors[survivorIndex] = element
      } else {
        losers.append(element)
      }
    }

    return (survivors, losers)
  }
}
