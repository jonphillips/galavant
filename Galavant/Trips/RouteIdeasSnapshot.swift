import GalavantSchema

/// Caches the distance calculation by the route and its candidate inputs. The
/// map may read this from several annotations during one render pass.
struct RouteIdeasSnapshot {
  private struct Input: Equatable {
    var route: [TravelEndpoint]
    var candidates: [Idea]
  }

  private var input: Input?
  private(set) var matches: [RouteCorridor.Match] = []
  private(set) var buildCount = 0

  mutating func matches(route: [TravelEndpoint], candidates: [Idea]) -> [RouteCorridor.Match] {
    let next = Input(route: route, candidates: candidates)
    guard input != next else { return matches }
    input = next
    matches = RouteCorridor.matches(route: route, ideas: candidates)
    buildCount += 1
    return matches
  }
}

enum RouteIdeaCandidates {
  static func filter(ideas: [Idea], tripIdeas: [TripIdea], day: Int) -> [Idea] {
    var entriesByIdea: [Idea.ID: [TripIdea]] = [:]
    for entry in tripIdeas {
      guard let ideaID = entry.ideaID else { continue }
      entriesByIdea[ideaID, default: []].append(entry)
    }
    return ideas.filter { idea in
      guard idea.latitude != nil, idea.longitude != nil, idea.kind != .stay else { return false }
      let entries = entriesByIdea[idea.id, default: []]
      guard !entries.contains(where: { $0.status == .declined }) else { return false }
      return !entries.contains(where: { $0.status == .scheduled && $0.dayNumber == day })
    }
  }
}
