import GalavantSchema

struct TripCanvasPreviewState: Equatable {
  enum TapAction: Equatable {
    case preview
    case showDetails
  }

  private(set) var stopID: TripIdea.ID?

  mutating func tap(_ stopID: TripIdea.ID) -> TapAction {
    guard self.stopID == stopID else {
      self.stopID = stopID
      return .preview
    }
    self.stopID = nil
    return .showDetails
  }

  mutating func clear() {
    stopID = nil
  }
}
