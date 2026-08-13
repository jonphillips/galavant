import Foundation
import GalavantSchema
import SwiftUI

extension CalendarReconciliationSheet {
  func planRepairRow(_ repair: CalendarPlanRepair) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(repair.title)
      Text(repair.kind.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
      if repair.isResolved {
        Label("Resolved", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Button("Mark Repair Resolved") { model.resolvePlanRepair(repair) }
          .font(.caption.weight(.semibold))
      }
    }
    .accessibilityElement(children: .combine)
  }

  func movedOutsideRow(_ linked: CalendarLinkedStop) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(linked.eventTitle ?? "Linked calendar event")
      Text("Its calendar event moved outside the trip dates. The itinerary stop was kept unchanged.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let moved = linked.movedOutsideTripCommitment {
        Text(temporalDescription(moved.temporal))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  func historyRow(_ entry: CalendarReconciliationLedgerEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.eventTitle)
      Text("Calendar commitment recorded.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let current = entry.current {
        Text(temporalDescription(current.temporal))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  func candidateRow(_ candidate: CalendarReconciliationCandidate) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(candidate.input.event.title)
      Text(candidate.input.event.calendarTitle)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(temporalDescription(candidate.input.event.temporal))
        .font(.caption)
        .foregroundStyle(.secondary)
      switch candidate.result {
      case let .automatic(stop, basis):
        Text("Matches \(stop.content.title) by \(basisDescription(basis)).")
          .font(.caption)
          .foregroundStyle(.green)
      case let .proposed(stop, basis):
        Text("Possible match: \(stop.content.title) by \(basisDescription(basis)).")
          .font(.caption)
      case let .ambiguous(stops):
        Text("Could be: \(stops.map(\.content.title).joined(separator: ", ")).")
          .font(.caption)
      case .unresolvedTimeZone:
        Text("Travel time zone needs review before this event can be placed on a trip day.")
          .font(.caption)
      case .unmatched:
        Text("No itinerary stop matches. Eligible events are added as trip constraints.")
          .font(.caption)
      }
    }
    .accessibilityElement(children: .combine)
  }

  func basisDescription(_ basis: CalendarMatchBasis) -> String {
    switch basis {
    case .mapItemIdentifier: "the same Apple Maps place"
    case .exactName: "the exact place name"
    case .nameAndProximity: "a nearby place with a shared name"
    }
  }

  func temporalDescription(_ temporal: CalendarEventTime) -> String {
    switch temporal {
    case let .absolute(start, _, timeZone):
      var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
      style.timeZone = timeZone
      return start.formatted(style)
    case let .floating(start, _):
      return String(
        format: "%d/%d/%04d %02d:%02d (floating)",
        start.date.month, start.date.day, start.date.year, start.hour, start.minute)
    case let .allDay(start, endExclusive):
      if endExclusive == start.adding(days: 1) {
        return String(format: "%d/%d/%04d (all day)", start.month, start.day, start.year)
      }
      let inclusiveEnd = endExclusive.adding(days: -1) ?? endExclusive
      return String(
        format: "%d/%d/%04d–%d/%d/%04d (all day)",
        start.month, start.day, start.year,
        inclusiveEnd.month, inclusiveEnd.day, inclusiveEnd.year)
    }
  }
}
