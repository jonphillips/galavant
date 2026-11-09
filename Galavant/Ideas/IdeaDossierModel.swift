import CasePaths
import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import Sharing

@MainActor
@Observable
final class IdeaDossierModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll var ideas: [Idea]
  @ObservationIgnored @FetchAll var evaluations: [IdeaEvaluation]
  @ObservationIgnored @FetchAll var interests: [IdeaInterest]
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll var notes: [TasteNote]
  @ObservationIgnored @FetchAll(Tag.all) var tags
  @ObservationIgnored @FetchAll var ideaTags: [IdeaTag]
  @ObservationIgnored @FetchAll var photoRows: [PhotoRow]
  @ObservationIgnored @FetchAll var headerRows: [HeaderRow]
  @ObservationIgnored @FetchAll var stops: [TripIdea]
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""
  @ObservationIgnored @Dependency(\.date) var date
  @ObservationIgnored @Dependency(\.calendar) var calendar

  let ideaID: Idea.ID
  var destination: Destination?

  @CasePathable
  enum Destination {
    case edit(IdeasListModel.IdeaFormPresentation)
    case photo(SelectedPhoto)
  }

  init(ideaID: Idea.ID) {
    self.ideaID = ideaID
    _ideas = FetchAll(Idea.where { $0.id.eq(ideaID) })
    _evaluations = FetchAll(IdeaEvaluation.where { $0.ideaID.eq(ideaID) })
    _interests = FetchAll(IdeaInterest.where { $0.ideaID.eq(ideaID) })
    _notes = FetchAll(TasteNote.where { $0.ideaID.eq(ideaID) }.order { $0.notedAt.desc() })
    _ideaTags = FetchAll(IdeaTag.where { $0.ideaID.eq(ideaID) })
    _photoRows = FetchAll(
      ImageAsset.where { $0.ideaID.eq(ideaID) }
        .select { PhotoRow.Columns(id: $0.id, ideaID: $0.ideaID, thumbnail: $0.thumbnail, sortRank: $0.sortRank, isHeader: $0.isHeader) }
    )
    _headerRows = FetchAll(
      ImageAsset.where { $0.ideaID.eq(ideaID) && $0.isHeader.eq(true) }
        .select { HeaderRow.Columns(display: $0.display) }
    )
    _stops = FetchAll(TripIdea.where { $0.ideaID.eq(ideaID) })
  }

  var dossier: IdeaDossier? {
    guard let idea = ideas.first else { return nil }
    return IdeaDossier(
      idea: idea,
      evaluations: evaluations,
      interests: interests,
      planners: planners.filter { $0.travelPartyID == idea.travelPartyID },
      notes: notes,
      tags: tags.filter { $0.travelPartyID == idea.travelPartyID },
      ideaTags: ideaTags,
      photos: photoRows.map { ($0.id, $0.ideaID, $0.thumbnail, $0.sortRank, $0.isHeader) },
      knownIdeaIDs: [idea.id], stops: stops, trips: trips, now: date(), calendar: calendar
    )
  }

  var headerImage: Data? { headerRows.first?.display }

  func editButtonTapped() {
    guard let idea = ideas.first else { return }
    destination = .edit(IdeasListModel.IdeaFormPresentation(draft: Idea.Draft(idea), searchRegions: []))
  }

  func setMyInterest(_ level: Interest?) {
    guard let plannerID = UUID(uuidString: currentPlannerIDString),
      planners.contains(where: { $0.id == plannerID }),
      let idea = ideas.first
    else { return }
    withErrorReporting {
      try database.write { db in
        try IdeaInterest.set(level: level, ideaID: idea.id, plannerID: plannerID, in: db)
      }
    }
  }

  func photoTapped(_ photo: DossierPhoto) async {
    await withErrorReporting {
      guard let display = try await database.read({ db in
        try ImageAsset.find(photo.id).fetchOne(db)?.display
      }) else { return }
      destination = .photo(SelectedPhoto(id: photo.id, display: display))
    }
  }

  @Selection
  struct PhotoRow {
    let id: ImageAsset.ID
    let ideaID: Idea.ID
    let thumbnail: Data
    let sortRank: Int
    let isHeader: Bool
  }

  @Selection
  struct HeaderRow {
    let display: Data
  }

  struct SelectedPhoto: Identifiable {
    let id: ImageAsset.ID
    let display: Data
  }
}
