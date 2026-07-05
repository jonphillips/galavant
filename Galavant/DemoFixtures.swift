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
      var regionIDByName: [String: MapRegion.ID] = [:]
      for (name, lat, lon) in regionSpecs {
        let regionID = UUID()
        try MapRegion.insert {
          MapRegion.Draft(
            id: regionID, name: name,
            centerLatitude: lat, centerLongitude: lon,
            latitudeDelta: 1.5, longitudeDelta: 1.5, travelPartyID: partyID
          )
        }
        .execute(db)
        regions.append((name, lat, lon))
        regionIDByName[name] = regionID
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
      var ratingDemo = 0
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
          // Cycle the first idea per region through a spread of his/hers states
          // so the rating bars + match signal have every case to show: a match
          // (both high), a mismatch, a Decide-Later-vs-pending pair, and a
          // mutual pass. (The i>0 ideas stay unrated — no his/hers row.)
          if i == 0 {
            switch ratingDemo % 4 {
            case 0:  // match — both want it
              try IdeaInterest.set(level: .mustDo, ideaID: ideaID, plannerID: jon.id, in: db)
              try IdeaInterest.set(level: .wantToDo, ideaID: ideaID, plannerID: sam.id, in: db)
            case 1:  // one high, one lukewarm — not a match
              try IdeaInterest.set(level: .mustDo, ideaID: ideaID, plannerID: jon.id, in: db)
              try IdeaInterest.set(level: .couldDo, ideaID: ideaID, plannerID: sam.id, in: db)
            case 2:  // Jon deferred, Sam not yet rated (Decide Later vs pending)
              try IdeaInterest.set(level: .decideLater, ideaID: ideaID, plannerID: jon.id, in: db)
            default:  // mutually passed
              try IdeaInterest.set(level: .doNotDo, ideaID: ideaID, plannerID: jon.id, in: db)
              try IdeaInterest.set(level: .doNotDo, ideaID: ideaID, plannerID: sam.id, in: db)
            }
            ratingDemo += 1
          }
        }
      }

      // A trip in each certainty stage, plus a couple more in the backlog, so
      // the sectioned Trips list is populated.
      let christmas = DateComponents(calendar: .current, year: 2027, month: 12, day: 18).date
      let tokyo = try Trip.create(name: "Tokyo", in: db)
      _ = try Trip.create(name: "Barcelona", in: db)
      let paris = try Trip.create(
        name: "Paris", certainty: .targeted(year: 2027, quarter: .q2), lengthInDays: 6, in: db
      )
      let copenhagen = try Trip.create(
        name: "Copenhagen", certainty: .dated(start: christmas ?? Date()), lengthInDays: 9, in: db
      )
      // Pre-associate planning regions so the Add lens has something to show.
      for (trip, regionName) in [(tokyo, "Tokyo"), (paris, "Paris"), (copenhagen, "Copenhagen")] {
        if let regionID = regionIDByName[regionName] {
          try TripRegion.setRegions([regionID], forTrip: trip.id, in: db)
        }
      }

      // Romance headers (ADR-0032) on a few trips so the Trips collection view has
      // real photos to show off; the rest fall back to the seeded gradient card.
      let demoHeaders: [(Trip, String, String)] = [
        (tokyo, "photo-1513639776629-7b61b0ac49cb", "#1B1B2F"),
        (paris, "photo-1540959733332-eab4deabeeaf", "#26262C"),
        (copenhagen, "photo-1533929736458-ca588d08c8be", "#0C3B5B"),
      ]
      for (trip, photo, color) in demoHeaders {
        try Trip.setHeaderImage(
          TripHeaderImage(
            url: "https://images.unsplash.com/\(photo)?w=800&q=80",
            color: color,
            photographerName: "Unsplash",
            photographerUsername: nil
          ),
          tripID: trip.id,
          in: db
        )
      }

      // A worked itinerary on the Tokyo trip so the map canvas has stops to draw:
      // real-ish located POIs over two days, each day a multi-stop sequence
      // (numbered, day-coloured pins + a per-day polyline). The other trips stay
      // empty to show the pre-itinerary canvas state.
      let tokyoStops: [(String, IdeaKind, Double, Double, Schedule)] = [
        ("Sensō-ji", .sight, 35.7148, 139.7967, .daypart(1, .morning)),
        ("Tokyo Skytree", .sight, 35.7101, 139.8107, .daypart(1, .lunch)),
        ("Ueno Park", .park, 35.7156, 139.7745, .daypart(1, .afternoon)),
        ("Meiji Jingū", .sight, 35.6764, 139.6993, .daypart(2, .morning)),
        ("Shibuya Crossing", .sight, 35.6595, 139.7004, .daypart(2, .afternoon)),
        ("teamLab Planets", .museum, 35.6256, 139.7831, .timed(2, start: "19:00", end: "21:00")),
      ]
      for (name, kind, lat, lon, schedule) in tokyoStops {
        let ideaID = UUID()
        try Idea.insert {
          Idea.Draft(
            id: ideaID, name: name, kind: kind, regionName: "Tokyo",
            latitude: lat, longitude: lon, travelPartyID: partyID
          )
        }
        .execute(db)
        _ = try TripIdea.pull(ideaID: ideaID, into: tokyo.id, in: db)
        try TripIdea.schedule(schedule, ideaID: ideaID, tripID: tokyo.id, in: db)
      }

      // A spread of trip associations across the pool so the Ideas-list
      // trip-badges show every derived state: upcoming (pulled onto an in-play
      // trip), someday (pulled onto a backlog trip), and visited. The pool ideas
      // are named "<Region> <Kind> <n>", distinct from the named Tokyo stops.
      func firstPoolIdea(in region: String) throws -> Idea.ID? {
        try Idea.where { $0.regionName.eq(region) }
          .order(by: \.name).fetchAll(db)
          .first { $0.name.hasPrefix(region) }?.id
      }
      if let id = try firstPoolIdea(in: "Copenhagen") {  // dated trip → upcoming
        _ = try TripIdea.pull(ideaID: id, into: copenhagen.id, in: db)
      }
      if let id = try firstPoolIdea(in: "Paris") {  // targeted trip → upcoming
        _ = try TripIdea.pull(ideaID: id, into: paris.id, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: id, tripID: paris.id, in: db)
      }
      if let id = try firstPoolIdea(in: "Tokyo") {  // backlog trip → someday
        _ = try TripIdea.pull(ideaID: id, into: tokyo.id, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: id, tripID: tokyo.id, in: db)
      }
      if let id = try firstPoolIdea(in: "Virginia") {  // no live association → visited
        try Idea.find(id).update { $0.visited = true }.execute(db)
      }

      return jon.id
    }
  }
#endif
