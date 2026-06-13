#if DEBUG
  import Dependencies
  import Foundation
  import GalavantSchema
  import Sharing
  import SQLiteData

  /// Populates a realistic, sizeable dataset on launch when `--seed-demo` is
  /// passed — for eyeballing the UI under load (many regions/tags/pins) and to
  /// skip hand-entering data in dev/UI-test runs. No-op once the pool is seeded.
  enum DemoFixtures {
    static func seedIfRequested() {
      guard CommandLine.arguments.contains("--seed-demo") else { return }
      @Dependency(\.defaultDatabase) var database
      @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""
      withErrorReporting {
        let me = try database.write { db -> UUID in
          if let existing = try Planner.all.fetchOne(db), try Idea.all.fetchCount(db) > 0 {
            return existing.id
          }
          return try seed(into: db)
        }
        $currentPlannerIDString.withLock { $0 = me.uuidString }
      }
    }

    private static func seed(into db: Database) throws -> UUID {
      let partyID = try TravelParty.ensureDefault(in: db).id
      let jon = try Planner.create(displayName: "Jon", in: db)
      let sam = try Planner.create(displayName: "Sam", in: db)

      let regionSpecs: [(String, Double, Double)] = [
        ("Virginia", 37.9, -78.5),
        ("Washington DC", 38.9, -77.03),
        ("Copenhagen", 55.68, 12.57),
        ("Paris", 48.86, 2.35),
        ("Tokyo", 35.68, 139.76),
        ("Barcelona", 41.39, 2.17),
        ("Rome", 41.9, 12.5),
        ("New York", 40.71, -74.0),
      ]
      var regions: [(String, Double, Double)] = []
      for (name, lat, lon) in regionSpecs {
        try MapRegion.insert {
          MapRegion.Draft(
            id: UUID(), name: name,
            centerLatitude: lat, centerLongitude: lon,
            latitudeDelta: 1.5, longitudeDelta: 1.5, travelPartyID: partyID
          )
        }
        .execute(db)
        regions.append((name, lat, lon))
      }

      let tagNames = [
        "Michelin", "kid-friendly", "rainy-day", "outdoors", "romantic", "budget",
        "splurge", "must-see", "hidden-gem", "foodie", "historic", "nightlife",
      ]
      var tagIDs: [String: Tag.ID] = [:]
      for name in tagNames {
        tagIDs[name] = try Tag.findOrCreate(named: name, in: db).id
      }

      let kinds: [IdeaKind] = [.food, .museum, .park, .sight, .stay, .nightlife, .beach, .shop]
      let latOffsets = [-0.4, 0.0, 0.4]
      let lonOffsets = [0.3, -0.2, 0.1]
      var k = 0
      var t = 0
      for (regionName, lat, lon) in regions {
        for i in 0..<3 {
          let kind = kinds[k % kinds.count]
          k += 1
          let ideaID = UUID()
          try Idea.insert {
            Idea.Draft(
              id: ideaID,
              name: "\(regionName) \(kind.label) \(i + 1)",
              kind: kind,
              regionName: regionName,
              latitude: lat + latOffsets[i],
              longitude: lon + lonOffsets[i],
              travelPartyID: partyID
            )
          }
          .execute(db)
          for _ in 0..<2 {
            try IdeaTag.add(tagID: tagIDs[tagNames[t % tagNames.count]]!, to: ideaID, in: db)
            t += 1
          }
          if i == 0 {
            try IdeaInterest.set(level: .mustDo, ideaID: ideaID, plannerID: jon.id, in: db)
            try IdeaInterest.set(level: .couldDo, ideaID: ideaID, plannerID: sam.id, in: db)
          }
        }
      }
      return jon.id
    }
  }
#endif
