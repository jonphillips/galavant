import GalavantSchema

/// Caches corridor geometry by route and candidate inputs, following the same
/// input-snapshot pattern as `TripPlanSnapshot`.
struct RouteIdeasSnapshot {
  private struct Input: Equatable {
    var route: [TravelEndpoint]
    var candidates: [RouteIdeaPinModel]
  }

  private var input: Input?
  private(set) var matches: [RouteIdeaPinModel] = []
  private(set) var buildCount = 0

  mutating func matches(route: [TravelEndpoint], candidates: [RouteIdeaPinModel]) -> [RouteIdeaPinModel] {
    let next = Input(route: route, candidates: candidates)
    guard input != next else { return matches }
    input = next
    let candidateByID = Dictionary(candidates.map { ($0.idea.id, $0) }, uniquingKeysWith: { first, _ in first })
    matches = RouteCorridor.matches(route: route, ideas: candidates.map(\.idea))
      .compactMap { candidateByID[$0.ideaID] }
    buildCount += 1
    return matches
  }
}

struct RouteIdeaPinModel: Equatable, Identifiable {
  var idea: Idea
  var latitude: Double
  var longitude: Double
  var isOnTrip: Bool

  var id: Idea.ID { idea.id }
}

enum RouteIdeaCandidates {
  static func filter(ideas: [Idea], tripIdeas: [TripIdea], day: Int) -> [RouteIdeaPinModel] {
    var entriesByIdea: [Idea.ID: [TripIdea]] = [:]
    for entry in tripIdeas {
      guard let ideaID = entry.ideaID else { continue }
      entriesByIdea[ideaID, default: []].append(entry)
    }
    return ideas.compactMap { idea in
      guard let latitude = idea.latitude, let longitude = idea.longitude, idea.kind != .stay else {
        return nil
      }
      let entries = entriesByIdea[idea.id, default: []]
      guard !entries.contains(where: { $0.status == .declined }) else { return nil }
      guard !entries.contains(where: { $0.status == .scheduled && $0.dayNumber == day }) else {
        return nil
      }
      return RouteIdeaPinModel(
        idea: idea, latitude: latitude, longitude: longitude, isOnTrip: !entries.isEmpty)
    }
  }
}
