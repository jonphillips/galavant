import SwiftUI

/// Apply a single-collection reorder to an ordered array of identifiable items
/// (Apple's documented pattern for `reorderContainer`). Shared by every screen
/// that drives a `reorderContainer` off a `@FetchAll`-backed array — the trips
/// backlog and the trip shortlist.
extension ReorderDifference where CollectionID == ReorderableSingleCollectionIdentifier {
  func apply<C>(to collection: inout C)
  where C: RangeReplaceableCollection, C.Element: Identifiable, C.Element.ID == ItemID {
    let moving = Set(sources)
    guard !moving.isEmpty else { return }

    var moved: [C.Element] = []
    moved.reserveCapacity(moving.count)
    collection.removeAll { element in
      guard moving.contains(element.id) else { return false }
      moved.append(element)
      return true
    }

    switch destination.position {
    case .before(let id):
      let index = collection.firstIndex { $0.id == id } ?? collection.endIndex
      collection.insert(contentsOf: moved, at: index)
    case .end:
      collection.append(contentsOf: moved)
    }
  }
}
