import Foundation
import GalavantSchema

/// What the chat is "looking at" (ADR-0017 §2). Built by the presenting screen
/// from already-fetched read-model values and serialized into the system prompt,
/// so the model is *seeded* with bounded, accurate context rather than turned
/// loose on the database. The taste profile (ADR-0015) is injected by the
/// `ModelClient` boundary, not re-plumbed here.
public enum ChatContext: Sendable, Equatable {
  /// An idea detail: the idea, its source evaluations, his/hers interest, tags.
  case idea(ResolvedIdeaContext)
  /// A trip canvas/itinerary: the resolved planning read-model.
  case trip(TripPlan)
  /// The Ideas shopping surface: the current filter lens + the visible ideas.
  case pool(PoolContext)

  /// A one-line label for the chat panel header — "what we're discussing."
  public var title: String {
    switch self {
    case let .idea(context): context.idea.name.isEmpty ? "this idea" : context.idea.name
    case .trip: "this trip"
    case let .pool(context): context.lens
    }
  }

  /// The context block spliced into the system prompt. Pure — the heart of the
  /// testable core; the `@Observable` model just wraps it.
  public func serialized() -> String {
    switch self {
    case let .idea(context): context.serialized()
    case let .trip(plan): ChatContext.serialize(trip: plan)
    case let .pool(context): context.serialized()
    }
  }
}

/// One planner's interest in the idea on screen — name + level, faithfully shown
/// (the his/hers signal, ADR-0015 §2; never merged with evaluations).
public struct PlannerInterest: Sendable, Equatable {
  public var plannerName: String
  public var level: Interest?

  public init(plannerName: String, level: Interest?) {
    self.plannerName = plannerName
    self.level = level
  }
}

/// The idea-detail context: the idea plus the three inputs the detail renders —
/// external evaluations, his/hers interest, and tags (ADR-0017 §2).
public struct ResolvedIdeaContext: Sendable, Equatable {
  public var idea: Idea
  public var evaluations: [IdeaEvaluation]
  public var interests: [PlannerInterest]
  public var tags: [String]

  public init(
    idea: Idea,
    evaluations: [IdeaEvaluation] = [],
    interests: [PlannerInterest] = [],
    tags: [String] = []
  ) {
    self.idea = idea
    self.evaluations = evaluations
    self.interests = interests
    self.tags = tags
  }

  func serialized() -> String {
    var lines = ["The user is looking at this idea:"]
    lines.append("- Name: \(idea.name.isEmpty ? "(unnamed)" : idea.name)")
    if let kind = idea.kind { lines.append("- Kind: \(kind.label)") }
    if let region = idea.regionName, !region.isEmpty { lines.append("- Region: \(region)") }
    if let address = idea.address, !address.isEmpty { lines.append("- Address: \(address)") }
    lines.append("- Visited: \(idea.visited ? "yes" : "no")")
    if let hours = idea.openingHours, !hours.isEmpty {
      lines.append("- Opening hours: \(hours.replacingOccurrences(of: "\n", with: "; "))")
    }
    if !idea.notes.isEmpty { lines.append("- Notes: \(idea.notes)") }
    if !evaluations.isEmpty {
      lines.append("- Source evaluations (shown exactly as the source rated it):")
      for evaluation in evaluations {
        lines.append("  - \(evaluation.sourceName): \(evaluation.nativeDisplay)")
      }
    }
    let rated = interests.filter { $0.level != nil }
    if !rated.isEmpty {
      let parts = rated.map { "\($0.plannerName): \($0.level?.label ?? "")" }
      lines.append("- Interest — \(parts.joined(separator: ", "))")
    }
    if !tags.isEmpty { lines.append("- Tags: \(tags.joined(separator: ", "))") }
    return lines.joined(separator: "\n")
  }
}

/// The pool context: the active filter lens (a human label like "Denmark · Food")
/// and the ideas currently visible under it (ADR-0017 §2). Bounded to what the
/// screen shows; pool-wide questions go through the `queryPool` tool.
public struct PoolContext: Sendable, Equatable {
  public var lens: String
  public var ideas: [Idea]

  public init(lens: String, ideas: [Idea]) {
    self.lens = lens
    self.ideas = ideas
  }

  func serialized() -> String {
    var lines = ["The user is browsing the idea pool. Current lens: \(lens)."]
    if ideas.isEmpty {
      lines.append("No ideas are visible under this lens.")
      return lines.joined(separator: "\n")
    }
    lines.append("Visible ideas (\(ideas.count)):")
    for idea in ideas.prefix(50) {
      lines.append("- \(ChatContext.summarize(idea))")
    }
    if ideas.count > 50 {
      lines.append("…and \(ideas.count - 50) more (use the queryPool tool for the full pool).")
    }
    return lines.joined(separator: "\n")
  }
}

extension ChatContext {
  /// One-line idea summary used by the pool and trip serializers.
  static func summarize(_ idea: Idea) -> String {
    var parts = [idea.name.isEmpty ? "(unnamed)" : idea.name]
    if let kind = idea.kind { parts.append(kind.label) }
    if let region = idea.regionName, !region.isEmpty { parts.append(region) }
    if idea.visited { parts.append("visited") }
    return parts.joined(separator: " — ")
  }

  static func serialize(trip plan: TripPlan) -> String {
    var lines = ["The user is looking at a trip (\(plan.lengthInDays) days)."]
    let itinerary = plan.itinerary.filter { !$0.stops.isEmpty }
    if itinerary.isEmpty {
      lines.append("Nothing is scheduled yet.")
    } else {
      lines.append("Scheduled itinerary:")
      for day in itinerary {
        lines.append("- Day \(day.number):")
        for stop in day.stops {
          lines.append("  - \(stop.content.title)")
        }
      }
    }
    let shortlist = plan.shortlist
    if !shortlist.isEmpty {
      lines.append("Shortlisted (not yet scheduled): "
        + shortlist.map { $0.content.title }.joined(separator: ", "))
    }
    if !plan.stays.isEmpty {
      lines.append("Accommodations: "
        + plan.stays.map { $0.content.title }.joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
  }
}
