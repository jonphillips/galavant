import Dependencies
import GalavantSchema
import SQLiteData

@MainActor
public final class MapPlaceCapture {
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.uuid) private var uuid

  public init() {}

  public func draft(for place: Place) async -> Idea.Draft {
    if let mapItemIdentifier = place.mapItemIdentifier,
      let existing = try? await database.read({ db in
        try Idea.where { $0.mapItemIdentifier.eq(mapItemIdentifier) }.fetchOne(db)
      })
    {
      return Idea.Draft(
        existing.supplemented(
          name: place.name,
          kind: place.kind,
          regionName: place.regionName,
          address: place.address,
          phone: place.phone,
          latitude: place.latitude,
          longitude: place.longitude,
          url: place.url ?? "",
          mapItemIdentifier: place.mapItemIdentifier
        )
      )
    }
    return Idea.Draft(place.idea(id: uuid()))
  }

  public func enrichIfNeeded(ideaID: Idea.ID) async {
    await PlaceEnricher().enrichIfNeeded(ideaID: ideaID)
  }
}
