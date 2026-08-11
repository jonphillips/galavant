import GalavantSchema

extension Place {
  public func idea(id: Idea.ID) -> Idea {
    Idea(
      id: id,
      name: name,
      kind: kind,
      regionName: regionName,
      address: address,
      phone: phone,
      latitude: latitude,
      longitude: longitude,
      url: url ?? "",
      mapItemIdentifier: mapItemIdentifier
    )
  }
}
