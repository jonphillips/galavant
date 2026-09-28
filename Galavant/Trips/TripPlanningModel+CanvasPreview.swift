import GalavantSchema

extension TripPlanningModel {
  /// A single resolved-stop lookup for the ephemeral marker, shared by the map
  /// annotation and its camera target.
  var canvasPreviewStop: ResolvedStop? {
    guard let canvasPreviewStopID else { return nil }
    return plan.stop(id: canvasPreviewStopID)
  }

  /// Focus a stop from the map or the timeline — the single shared selection both
  /// surfaces project. Brings the Itinerary tab forward so the row is visible.
  func selectStop(_ id: TripIdea.ID?) {
    if id != nil { clearCanvasPreview() }
    canvasSelectedStopID = id
    if id != nil { sheetTab = .itinerary }
  }

  func clearCanvasPreview() {
    canvasPreviewState.clear()
  }

  /// First tap previews a located row; tapping it again opens its full detail.
  /// Rows already represented by a visible itinerary pin use the shared selection.
  func tripIdeaRowTapped(_ stop: ResolvedStop, isDrawnOnCanvas: Bool) {
    if isDrawnOnCanvas {
      switch TripCanvasPreviewState.drawnRowTapAction(
        stopID: stop.id,
        selectedStopID: canvasSelectedStopID
      ) {
      case .select:
        clearCanvasPreview()
        canvasSelectedStopID = stop.id
      case .showDetails:
        if let idea = stop.idea { showDetail(idea, stopID: stop.id) }
        else { destination = .recommendationDetail(stop.id) }
      }
      return
    }

    if stop.coordinate != nil {
      var state = canvasPreviewState
      let action = state.tap(stop.id)
      canvasPreviewState = state
      switch action {
      case .preview:
        canvasSelectedStopID = nil
      case .showDetails:
        if let idea = stop.idea { showDetail(idea, stopID: stop.id) }
        else { destination = .recommendationDetail(stop.id) }
      }
    } else if let idea = stop.idea {
      clearCanvasPreview()
      showDetail(idea, stopID: stop.id)
    } else {
      clearCanvasPreview()
      destination = .recommendationDetail(stop.id)
    }
  }

  func canvasPreviewPinTapped(_ stopID: TripIdea.ID) {
    guard let stop = canvasPreviewStop, stop.id == stopID else { return }
    clearCanvasPreview()
    if let idea = stop.idea { showDetail(idea, stopID: stop.id) }
    else { destination = .recommendationDetail(stop.id) }
  }
}

extension TripCanvasPreviewState {
  enum DrawnRowTapAction: Equatable {
    case select
    case showDetails
  }

  static func drawnRowTapAction(
    stopID: TripIdea.ID,
    selectedStopID: TripIdea.ID?
  ) -> DrawnRowTapAction {
    selectedStopID == stopID ? .showDetails : .select
  }
}
