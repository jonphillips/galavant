import CoreLocation
import Foundation
import GalavantSchema

/// The editable state of the custom-stop sheet — author a new freeform stop or
/// edit an existing one. `stopID == nil` means creating; a set id means editing
/// that stop in place (ADR-0010 Slice 3). `day` (nil = To Be Scheduled) is the
/// landing day chosen at create time; on edit, placement is the `StopMenu`'s job
/// and the picker is hidden. Identifiable so it drives a `.sheet(item:)` like
/// `Trip.Draft` does.
struct FreeformStopDraft: Identifiable {
  let id = UUID()
  var stopID: TripIdea.ID?
  var alternativeToStopID: TripIdea.ID?
  var title = ""
  var note = ""
  var coordinate: CLLocationCoordinate2D?
  var day: Int?
  var booking = BookingFieldsDraft()
}

struct AlternativeSourceTarget: Identifiable {
  let id = UUID()
  let targetStopID: TripIdea.ID
}

struct AlternativeSlotTarget: Identifiable {
  let id = UUID()
  let sourceStopID: TripIdea.ID
}

/// Which itinerary section a per-section "+" is adding into — a day, or the To
/// Be Scheduled bucket (`day == nil`). Identifiable so each tap drives a fresh
/// `.sheet(item:)` (ADR-0010 Slice 3).
struct PlaceIdeaTarget: Identifiable {
  let id = UUID()
  let day: Int?
}

/// A place selected directly from the Apple Maps canvas, awaiting the normal
/// confirm-and-tweak idea form. The UUID gives every tap its own sheet identity.
struct MapPlaceIdea: Identifiable {
  let id = UUID()
  let draft: Idea.Draft
}

/// An existing pool idea opened from an itinerary row. The draft is wrapped so
/// presentation has stable identity even before a new idea has been persisted.
struct TripIdeaEditPresentation: Identifiable {
  let id: UUID
  let draft: Idea.Draft

  init(_ idea: Idea) {
    id = idea.id
    draft = Idea.Draft(idea)
  }
}

/// The editable state of the stop clock-time editor (ADR-0033 Slice 4) — give a
/// placed stop an exact `.timed` start (and optional end) on its `day`. `start`
/// is pre-filled from `Schedule.suggestedTime` over the stop's ordered-day
/// neighbors (or its own start when already timed); `end` mirrors the stay
/// editor's optional-time toggle. Identifiable (keyed on the stop) so it drives a
/// `.sheet(item:)`.
struct StopTimeDraft: Identifiable {
  var stopID: TripIdea.ID
  var day: Int
  var start: String
  var end: String?
  var id: TripIdea.ID { stopID }
}

/// The editable state of the lodging sheet — author a new stay or edit one in
/// place (ADR-0011). `stayID == nil` means creating. `ideaID` set means the stay
/// is backed by a pool hotel (chosen in the sheet's Hotel picker, or seeded by
/// "Stay here") and `title`/`note` are unused; `ideaID == nil` is a freeform stay
/// whose `title`/`note` carry it. `checkInDay`/`checkOutDay` are the span; optional
/// `"HH:mm"` times default to evening / morning ordering. Identifiable so each
/// presentation drives a fresh `.sheet(item:)`.
struct StayDraft: Identifiable {
  let id = UUID()
  var stayID: TripStay.ID?
  var ideaID: Idea.ID?
  var title = ""
  var note = ""
  var checkInDay = 1
  var checkOutDay = 2
  var checkInTime: String?
  var checkOutTime: String?
  var plannedCheckInTime: String?
  var plannedCheckOutTime: String?

  /// Backed by a pool hotel (vs. a freeform stay) — the sheet hides the title
  /// field and shows the hotel name instead.
  var isIdeaBacked: Bool { ideaID != nil }
}

/// Entry-scoped reservation fields shared by the idea-backed stop editor and the
/// freeform stop editor. A pin is optional; blank booking metadata is stored as nil.
struct BookingFieldsDraft {
  var isPinned = false
  var date = Date.now
  var confirmationNumber = ""
  var bookingURL = ""
  var partySize = ""
}

/// The entry-scoped editor for an idea-backed itinerary stop. The optional idea is
/// only a link to the shared Idea editor; the note and booking fields belong to the
/// TripIdea entry and are saved here.
struct StopEditorDraft: Identifiable {
  var stopID: TripIdea.ID
  var stopTitle: String
  var idea: Idea?
  var note: String
  var booking: BookingFieldsDraft
  var calendarLinked: Bool
  var id: TripIdea.ID { stopID }
}
