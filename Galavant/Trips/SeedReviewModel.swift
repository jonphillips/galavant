import Dependencies
import Foundation
import GalavantAI
import GalavantSchema
import SQLiteData

@MainActor
@Observable
final class SeedReviewModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.handoffSessionStore) private var handoffSessionStore
  @ObservationIgnored @Dependency(\.date) private var date

  var plan: SeedPlan?
  var error: String?

  func paste(_ strings: [String], for session: HandoffSession, context: SeedPlanContext?) {
    guard let pasted = strings.first, let context else { return }
    do {
      var warnings: [String] = []
      let bodyText: String
      if let routed = try? HandoffRouting.route(pasted) {
        bodyText = routed.text
        if routed.sessionID != session.id {
          warnings.append("This result was tagged for a different handoff — added it to this trip anyway.")
        }
      } else {
        bodyText = pasted
        warnings.append("This result had no Galavant handoff token — added it to this trip anyway.")
      }
      let contract = try RecommendationHandoffContract.marker.strippingMarker(from: bodyText)
      if let warning = contract.warning { warnings.append(warning) }
      var decoded = try SeedReturn.decode(contract.text)
      decoded.warnings.insert(contentsOf: warnings, at: 0)
      plan = SeedPlan.make(from: decoded, trip: context.trip, context: context)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  @discardableResult
  func commit(from session: HandoffSession) -> Bool {
    guard let plan else { return false }
    do {
      let importedSession = try database.write { db in
        try SeedPlan.commit(plan, tripID: session.sourceID, session: session, now: date.now, in: db)
      }
      try handoffSessionStore.save(importedSession)
      self.plan = nil
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
}
