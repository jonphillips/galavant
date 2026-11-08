import GalavantSchema

extension TripPlanningModel {
  /// Each planner's rated interest in an idea (skipping unrated rows), ordered by
  /// name — the his/hers display on the detail sheet.
  func interests(for idea: Idea) -> [(planner: Planner, level: Interest)] {
    interestRows
      .filter { $0.ideaID == idea.id && $0.level != nil }
      .compactMap { row in
        guard let planner = planners.first(where: { $0.id == row.plannerID }),
          let level = row.level
        else { return nil }
        return (planner, level)
      }
      .sorted { $0.planner.displayName < $1.planner.displayName }
  }

  /// Source evaluations for an idea, orphan-drops applied. Most-recently-recorded
  /// first — the evaluations detail section's data source (ADR-0015).
  func evaluations(for idea: Idea) -> [IdeaEvaluation] {
    IdeaEvaluation.evaluations(
      forIdea: idea.id,
      from: allEvaluations,
      knownIdeaIDs: Set(ideas.map(\.id))
    )
  }
}
