import Foundation
import GalavantSchema

extension TripPlanningModel {
  var trip: Trip? { trips.first { $0.id == tripID } }

  var headerThumbnailByIdea: [Idea.ID: Data] {
    Dictionary(headerThumbs.map { ($0.ideaID, $0.thumbnail) }, uniquingKeysWith: { first, _ in first })
  }

  var entries: [TripIdea] { allTripIdeas.filter { $0.tripID == tripID } }

  var tripDocumentCount: Int { tripDocumentRows.count }
}
