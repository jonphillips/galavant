import GalavantSchema
import Testing

struct InterestMatchTests {
  @Test func isHighOnlyForWantAndMust() {
    #expect(Interest.mustDo.isHigh)
    #expect(Interest.wantToDo.isHigh)
    #expect(!Interest.couldDo.isHigh)
    #expect(!Interest.doNotDo.isHigh)
    #expect(!Interest.decideLater.isHigh)
  }

  @Test func barFillSpreadsThePositivesAndDropsTheGlyphLevels() {
    #expect(Interest.mustDo.barFill == 4)
    #expect(Interest.wantToDo.barFill == 3)
    #expect(Interest.couldDo.barFill == 1)
    #expect(Interest.doNotDo.barFill == nil)
    #expect(Interest.decideLater.barFill == nil)
  }

  @Test func matchNeedsTwoHighRatings() {
    #expect(Interest.isMatch([.mustDo, .wantToDo]))
    #expect(Interest.isMatch([.wantToDo, .wantToDo]))
    // One high isn't enough; Could Do / Decide Later don't count as high.
    #expect(!Interest.isMatch([.mustDo, .couldDo]))
    #expect(!Interest.isMatch([.mustDo, .decideLater]))
    #expect(!Interest.isMatch([.mustDo, nil]))
    #expect(!Interest.isMatch([.couldDo, .couldDo]))
  }

  @Test func standingTiers() {
    #expect(Interest.standing([.mustDo, .wantToDo]) == .match)
    #expect(Interest.standing([.doNotDo, .doNotDo]) == .passed)
    // A high rating keeps it out of "passed" even if someone said no.
    #expect(Interest.standing([.mustDo, .doNotDo]) == .neutral)
    #expect(Interest.standing([.couldDo, nil]) == .neutral)
    #expect(Interest.standing([]) == .neutral)
  }

  @Test func sortKeyOrdersMatchesFirstPassedLast() {
    let keys = [MatchStanding.match, .neutral, .passed].map(\.sortKey)
    #expect(keys == keys.sorted())
  }
}
