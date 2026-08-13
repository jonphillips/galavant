import Foundation

public struct CandidateSetTraversal: Equatable, Sendable {
  public let orderedIDs: [TripIdea.ID]

  public init(candidates: [TripIdea]) {
    orderedIDs = candidates
      .sorted {
        ($0.shortlistRank, $0.id.uuidString) < ($1.shortlistRank, $1.id.uuidString)
      }
      .map(\.id)
  }

  public var isEmpty: Bool { orderedIDs.isEmpty }

  public func active(preferredID: TripIdea.ID?) -> TripIdea.ID? {
    guard !orderedIDs.isEmpty else { return nil }
    return preferredID.flatMap { orderedIDs.contains($0) ? $0 : nil } ?? orderedIDs[0]
  }

  public func next(after id: TripIdea.ID) -> TripIdea.ID? {
    guard let index = orderedIDs.firstIndex(of: id) else { return active(preferredID: nil) }
    return orderedIDs[(index + 1) % orderedIDs.count]
  }

  public func activeAfterProcessing(_ id: TripIdea.ID) -> TripIdea.ID? {
    let remaining = orderedIDs.filter { $0 != id }
    guard !remaining.isEmpty else { return nil }
    guard let index = orderedIDs.firstIndex(of: id) else { return remaining[0] }
    for offset in 1..<orderedIDs.count {
      let candidate = orderedIDs[(index + offset) % orderedIDs.count]
      if candidate != id { return candidate }
    }
    return remaining[0]
  }
}

public enum CandidateMapMarkerState: Equatable, Sendable {
  case fuzzy(isActive: Bool)
  case resolved(isActive: Bool)

  public static func state(for candidate: TripIdea, activeID: TripIdea.ID) -> Self {
    let isActive = candidate.id == activeID
    return candidate.ideaID == nil ? .fuzzy(isActive: isActive) : .resolved(isActive: isActive)
  }
}
