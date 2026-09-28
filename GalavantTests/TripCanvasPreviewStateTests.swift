import GalavantSchema
import Testing

@testable import Galavant

struct TripCanvasPreviewStateTests {
  @Test func firstTapSetsPreview() {
    var state = TripCanvasPreviewState()
    let stopID = TripIdea.ID()

    #expect(state.tap(stopID) == .preview)
    #expect(state.stopID == stopID)
  }

  @Test func tappingAnotherStopMovesPreview() {
    var state = TripCanvasPreviewState()
    let firstID = TripIdea.ID()
    let secondID = TripIdea.ID()
    _ = state.tap(firstID)

    #expect(state.tap(secondID) == .preview)
    #expect(state.stopID == secondID)
  }

  @Test func secondTapClearsPreviewAndOpensDetails() {
    var state = TripCanvasPreviewState()
    let stopID = TripIdea.ID()
    _ = state.tap(stopID)

    #expect(state.tap(stopID) == .showDetails)
    #expect(state.stopID == nil)
  }

  @Test func clearRemovesPreview() {
    var state = TripCanvasPreviewState()
    _ = state.tap(TripIdea.ID())

    state.clear()

    #expect(state.stopID == nil)
  }
}
