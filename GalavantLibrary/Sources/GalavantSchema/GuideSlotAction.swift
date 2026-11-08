import Foundation
import SQLiteData

/// A deliberate placement offered by a region guide.
public enum GuideSlotAction: Equatable, Sendable {
  case schedule(day: Int, DayPart)
  case addOption(to: TripIdea.ID)
  case move(stopID: TripIdea.ID, day: Int, DayPart)
  case shortlist
  case stay(nights: ClosedRange<Int>)

  /// Applies the entire guide choice inside the caller's database transaction.
  public func apply(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    switch self {
    case let .schedule(day, part):
      let entry = try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
      try TripIdea.setStatus(.shortlisted, stopID: entry.id, in: db)
      try TripIdea.schedule(.daypart(day, part), stopID: entry.id, in: db)
    case let .addOption(targetID):
      let entry = try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
      try TripIdea.setStatus(.shortlisted, stopID: entry.id, in: db)
      try TripIdea.addAlternative(sourceStopID: entry.id, to: targetID, in: db)
    case let .move(stopID, day, part):
      try TripIdea.schedule(.daypart(day, part), stopID: stopID, in: db)
    case .shortlist:
      let entry = try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
      try TripIdea.setStatus(.shortlisted, stopID: entry.id, in: db)
    case let .stay(nights):
      _ = try TripStay.create(
        tripID: tripID, ideaID: ideaID,
        checkInDay: nights.lowerBound, checkOutDay: nights.upperBound + 1, in: db)
    }
  }
}

/// The guide's Add to Trip choices, including disabled rows with an explanation.
public struct GuideSlotMenu: Equatable, Sendable {
  public struct Row: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var action: GuideSlotAction?
    public var isCurrent: Bool
  }

  public var sections: [[Row]]

  public init(lens: GuideTripLens, idea: Idea, entries: [TripIdea], stays: [TripStay], calendar: Calendar) {
    let currentStay = stays.first { $0.ideaID == idea.id }
    switch lens.body {
    case let .meals(days):
      sections = days.map { day in
        [(.lunch, day.lunch), (.dinner, day.dinner)].map { meal, cell in
          let weekday = day.date.flatMap { Weekday.from($0, calendar: calendar) } ?? day.weekday
          return Self.mealRow(meal: meal, cell: cell, day: day.day, weekday: weekday,
            idea: idea, entries: entries)
        }
      } + [[Self.shortlistRow(idea: idea, entries: entries)]]
    case let .nights(runs):
      sections = runs.map { run in
        switch run {
        case let .open(nights):
          return [Row(id: "stay-\(nights.lowerBound)", title: Self.nightsTitle(nights),
            detail: currentStay.map { "Already staying · Nights \($0.checkInDay)–\($0.checkOutDay - 1)" } ?? "Open nights",
            action: currentStay == nil ? .stay(nights: nights) : nil, isCurrent: false)]
        case let .stay(_, stayIdeaID, title, _, nights):
          return [Row(id: "stay-\(nights.lowerBound)", title: Self.nightsTitle(nights),
            detail: stayIdeaID == idea.id ? "Current stay · \(title)" : "Occupied by \(title)",
            action: nil, isCurrent: stayIdeaID == idea.id)]
        }
      }
    }
  }

  private static func mealRow(
    meal: Meal, cell: GuideTripLens.MealCell, day: Int, weekday: Weekday?, idea: Idea,
    entries: [TripIdea]
  ) -> Row {
    let title = "\(weekday?.shortLabel ?? "Day \(day)") \(meal.label.lowercased())"
    let current = entries.first { $0.ideaID == idea.id }
    let part: DayPart = meal == .lunch ? .lunch : .dinner
    let action: GuideSlotAction?
    let detail: String
    switch cell {
    case .open:
      let serves = weekday.flatMap { idea.weeklyHours?.serves(meal, on: $0) }
      if serves == false {
        if let weekday {
          let isClosed = idea.weeklyHours.map { $0[weekday].isClosed } ?? false
          detail = isClosed ? "Closed \(weekday.label)s" : "No \(meal.label.lowercased()) on \(weekday.label)s"
        } else {
          detail = "Closed"
        }
        action = nil
      } else if let current, current.status == .scheduled, current.alternativeGroupID != nil {
        detail = "One of the options for \(title)"
        action = nil
      } else if let current, current.status == .scheduled, current.alternativeGroupID == nil {
        let isCurrent = Self.matches(current.schedule, day: day, meal: meal)
        detail = isCurrent ? "Already on \(title)" : "Move here"
        action = isCurrent ? nil : .move(stopID: current.id, day: day, part)
      } else {
        detail = "Open slot"
        action = GuideSlotAction.schedule(day: day, part)
      }
    case let .filled(stops):
      if let current, current.status == .scheduled {
        detail = current.alternativeGroupID == nil ? "Already on \(title)" : "One of the options for \(title)"
        action = nil
      } else if let stop = stops.first {
        detail = "Add as an option to \(stop.title) · \(stop.optionCount) options"
        action = GuideSlotAction.addOption(to: stop.id)
      } else {
        detail = "Open slot"
        action = GuideSlotAction.schedule(day: day, part)
      }
    }
    return Row(id: "\(day)-\(meal.rawValue)", title: title, detail: detail,
      action: action, isCurrent: current.map { $0.status == .scheduled && Self.matches($0.schedule, day: day, meal: meal) } ?? false)
  }

  private static func matches(_ schedule: Schedule, day: Int, meal: Meal) -> Bool {
    switch schedule {
    case let .daypart(number, part) where number == day:
      return part == (meal == .lunch ? .lunch : .dinner)
    case let .timed(number, start, _) where number == day:
      guard let minute = Schedule.minutes(from: start) else { return false }
      return Meal.forClock(minute: minute) == meal
    default:
      return false
    }
  }

  private static func shortlistRow(idea: Idea, entries: [TripIdea]) -> Row {
    let entry = entries.first { $0.ideaID == idea.id }
    return Row(id: "shortlist", title: "Trip shortlist",
      detail: entry?.status == .shortlisted ? "Already shortlisted" : "Add to shortlist",
      action: entry?.status == .scheduled || entry?.status == .shortlisted ? nil : .shortlist,
      isCurrent: entry?.status == .shortlisted)
  }

  private static func nightsTitle(_ nights: ClosedRange<Int>) -> String {
    "Stay here · Nights \(nights.lowerBound)\(nights.lowerBound == nights.upperBound ? "" : "–\(nights.upperBound)")"
  }
}
