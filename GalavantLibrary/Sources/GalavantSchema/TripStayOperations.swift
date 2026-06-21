import Foundation
import SQLiteData

extension TripStay {
  // MARK: - Validation (pure)

  /// A stay's day span is valid only when check-out is strictly after check-in
  /// (a stay covers at least one night). The write path coerces invalid spans;
  /// the UI uses this to gate Save. Pure.
  public static func isValidSpan(checkInDay: Int, checkOutDay: Int) -> Bool {
    checkInDay >= 1 && checkOutDay > checkInDay
  }

  /// Coerce a span to a valid one: clamp check-in to ≥ 1 and force check-out to at
  /// least the night after check-in, so a write never stores a zero-night stay.
  static func coercedSpan(checkInDay: Int, checkOutDay: Int) -> (checkIn: Int, checkOut: Int) {
    let checkIn = Swift.max(1, checkInDay)
    return (checkIn, Swift.max(checkIn + 1, checkOutDay))
  }

  // MARK: - Write ops (ADR-0011)

  /// "Stay here" — stamp a pool hotel as a stay across `checkInDay…checkOutDay`.
  /// The referenced idea keeps its own pool lifecycle untouched (a stay opts out
  /// of considering → shortlisted → scheduled, like a freeform stop). Span is
  /// coerced valid. Returns the new id.
  @discardableResult
  public static func create(
    tripID: Trip.ID,
    ideaID: Idea.ID,
    checkInDay: Int,
    checkOutDay: Int,
    checkInTime: String? = nil,
    checkOutTime: String? = nil,
    in db: Database
  ) throws -> TripStay.ID {
    let span = coercedSpan(checkInDay: checkInDay, checkOutDay: checkOutDay)
    let id = UUID()
    try TripStay.insert {
      TripStay.Draft(
        id: id, tripID: tripID, ideaID: ideaID,
        checkInDay: span.checkIn, checkOutDay: span.checkOut,
        checkInTime: checkInTime, checkOutTime: checkOutTime)
    }
    .execute(db)
    return id
  }

  /// "Add lodging" — a freeform stay with no pool hotel (an unsaved Airbnb,
  /// "staying with friends"). `title` carries it; span is coerced valid. Returns
  /// the new id.
  @discardableResult
  public static func createFreeform(
    tripID: Trip.ID,
    title: String,
    note: String? = nil,
    checkInDay: Int,
    checkOutDay: Int,
    checkInTime: String? = nil,
    checkOutTime: String? = nil,
    in db: Database
  ) throws -> TripStay.ID {
    let span = coercedSpan(checkInDay: checkInDay, checkOutDay: checkOutDay)
    let id = UUID()
    try TripStay.insert {
      TripStay.Draft(
        id: id, tripID: tripID, ideaID: nil,
        inlineTitle: title, inlineNote: note,
        checkInDay: span.checkIn, checkOutDay: span.checkOut,
        checkInTime: checkInTime, checkOutTime: checkOutTime)
    }
    .execute(db)
    return id
  }

  /// Edit a stay's identity, span, and times. `ideaID` set ⇒ the stay is backed by
  /// that pool hotel and the inline content is cleared; `ideaID == nil` ⇒ a
  /// freeform stay carrying `title`/`note`. This lets the editor switch a stay
  /// between a pool hotel and a custom name. Span is coerced valid. No-op on a
  /// missing stay.
  public static func edit(
    stayID: TripStay.ID,
    ideaID: Idea.ID?,
    title: String? = nil,
    note: String? = nil,
    checkInDay: Int,
    checkOutDay: Int,
    checkInTime: String? = nil,
    checkOutTime: String? = nil,
    in db: Database
  ) throws {
    guard try TripStay.find(stayID).fetchOne(db) != nil else { return }
    let span = coercedSpan(checkInDay: checkInDay, checkOutDay: checkOutDay)
    try TripStay.find(stayID)
      .update {
        $0.ideaID = #bind(ideaID)
        // An idea-backed stay takes its name from the pool hotel, so drop any
        // stale inline content; a freeform stay carries title/note.
        $0.inlineTitle = #bind(ideaID == nil ? title : nil)
        $0.inlineNote = #bind(ideaID == nil ? note : nil)
        $0.checkInDay = #bind(span.checkIn)
        $0.checkOutDay = #bind(span.checkOut)
        $0.checkInTime = #bind(checkInTime)
        $0.checkOutTime = #bind(checkOutTime)
      }
      .execute(db)
  }

  /// Delete a stay from the trip entirely.
  public static func remove(stayID: TripStay.ID, in db: Database) throws {
    try TripStay.find(stayID).delete().execute(db)
  }
}
