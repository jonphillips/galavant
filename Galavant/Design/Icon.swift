import SwiftUI

/// The app's icon vocabulary: every SF Symbol used in chrome/actions, named by
/// *role* not glyph, so a symbol swaps in one place and call sites read as intent
/// (`Icon.edit`, not `"pencil"`). A mistyped symbol can't reach a view — the case
/// is the only spelling. Domain enums (`IdeaKind`, `DayPart`) keep their own
/// `systemImage`; this is for shared affordances.
enum Icon {
  // Create / edit / destroy
  case add            // primary add (toolbar / list)
  case addInline      // inline "create this" affordance
  case defineRegion   // create a map region
  case edit
  case delete         // permanently remove
  case remove         // take out of a set (e.g. a tag)
  case skip           // mark a stop skipped
  case revert         // move back / undo a placement

  // Status / controls
  case checkmark      // selected / confirmed
  case disclosure     // row chevron
  case filterActive   // filter control, engaged
  case manage         // manage / adjust (regions, tags)
  case tagPicker      // open the multi-select tag picker
  case info           // open a read-only detail
  case sidebar
  case settings       // app settings / "You" area
  case browser        // the in-app web browser section (ADR-0023)
  case aiOnDevice     // on-device (private) AI tier
  case aiFrontier     // frontier (networked, BYO-key) AI tier
  case chat           // open the context-aware chat panel (ADR-0017)
  case recommend      // external recommendation handoff (ADR-0036)
  case alternatives   // an itinerary slot with interchangeable options (ADR-0035)
  case cycleAlternative // rotate the active option in an alternatives ring (ADR-0035)
  case promoteAlternative // turn an option into an independent itinerary stop (ADR-0035)

  // Scheduling
  case calendar       // generic / "nothing scheduled"
  case schedule       // place a stop on a day
  case unschedule     // pull a stop off its day
  case toBeScheduled  // committed but dayless
  case timeOfDay      // set/no time-of-day on a placed stop
  case setTime        // give a placed stop an exact clock time (ADR-0033)
  case moveEarlier    // reorder a stop one slot earlier in its day (ADR-0033)
  case moveLater      // reorder a stop one slot later in its day (ADR-0033)
  case pinnedReservation  // a confirmed booking nailed to an absolute date (trip-time-model.md §4)
  case someday        // held in a someday trip / backlog
  case stay           // an accommodation / home base (ADR-0011)
  case checkIn        // arriving at a stay
  case checkOut       // leaving a stay

  // Travel
  case walk           // walking travel-time connector between stops

  // Places
  case map
  case location       // a stop/idea that has coordinates
  case headerImage    // choose/change a trip's "romance" header photo (ADR-0032)

  // Domains / sections
  case trips
  case ideas
  case shortlist
  case consider       // weighing an idea for a trip (the "maybe")
  case interest
  case tag
  case travelParty
  case emptyPool      // empty idea pool

  var systemName: String {
    switch self {
    case .add: "plus"
    case .addInline: "plus.circle"
    case .defineRegion: "plus.viewfinder"
    case .edit: "pencil"
    case .delete: "trash"
    case .remove: "minus.circle.fill"
    case .skip: "xmark.circle"
    case .revert: "arrow.uturn.backward"
    case .checkmark: "checkmark"
    case .disclosure: "chevron.right"
    case .filterActive: "line.3.horizontal.decrease.circle.fill"
    case .manage: "slider.horizontal.3"
    case .tagPicker: "checklist"
    case .info: "info.circle"
    case .sidebar: "sidebar.left"
    case .settings: "gearshape"
    case .browser: "globe"
    case .aiOnDevice: "lock.iphone"
    case .aiFrontier: "cloud"
    case .calendar: "calendar"
    case .schedule: "calendar.badge.plus"
    case .unschedule: "calendar.badge.minus"
    case .toBeScheduled: "calendar.badge.clock"
    case .timeOfDay: "clock"
    case .setTime: "clock.badge"
    case .moveEarlier: "arrow.up"
    case .moveLater: "arrow.down"
    case .pinnedReservation: "pin.fill"
    case .someday: "bookmark"
    case .stay: "bed.double"
    case .checkIn: "arrow.down.to.line"
    case .checkOut: "arrow.up.to.line"
    case .walk: "figure.walk"
    case .map: "map"
    case .location: "mappin.circle.fill"
    case .headerImage: "photo"
    case .trips: "suitcase"
    case .ideas: "lightbulb"
    case .shortlist: "star"
    case .consider: "questionmark.bubble"
    case .interest: "heart.fill"
    case .tag: "tag"
    case .travelParty: "person.2"
    case .emptyPool: "tray"
    case .chat: "bubble.left.and.text.bubble.right"
    case .recommend: "sparkles"
    case .alternatives: "arrow.triangle.2.circlepath"
    case .cycleAlternative: "arrow.triangle.2.circlepath"
    case .promoteAlternative: "arrow.up.right.square"
    }
  }

  /// The raw glyph (icon-only buttons, decorative images).
  var image: Image { Image(systemName: systemName) }

  /// A titled label — the common `Label("…", systemImage:)` shape.
  func label(_ title: LocalizedStringKey) -> Label<Text, Image> {
    Label(title, systemImage: systemName)
  }
}
