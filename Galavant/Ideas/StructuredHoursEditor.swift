import GalavantSchema
import SwiftUI

/// The hand-editable structured weekday-hours grid in the Idea form (ADR-0029 §5): a
/// row per weekday to set Unknown / Closed / Open, and for open days the service
/// "sittings" — an optional meal label and optional clock interval each. Any edit
/// stamps `hoursProvenance = .manual` (via `IdeaFormModel.structuredHoursEdited`), so
/// the hand edit wins over re-enrichment. The free-form captured string stays shown in
/// the sibling Hours section; this is the derived structure the start-day solver reads.
struct StructuredHoursEditor: View {
  @Bindable var model: IdeaFormModel

  var body: some View {
    Section {
      ForEach(Weekday.allCases, id: \.self) { weekday in
        DayHoursRow(
          weekday: weekday,
          day: Binding(
            get: { model.weeklyHours[weekday] },
            set: {
              model.weeklyHours[weekday] = $0
              model.structuredHoursEdited()
            }
          )
        )
      }
    } header: {
      Text("Weekly hours")
    } footer: {
      Text(
        "Open, closed, or unknown per weekday — with meal service where it matters. "
          + "Powers the trip start-day check. Editing here overrides auto-filled hours."
      )
    }
  }
}

/// One weekday's row: a status control, and — when open — its service sittings.
private struct DayHoursRow: View {
  let weekday: Weekday
  @Binding var day: DayHours

  private enum Status: String, CaseIterable { case unknown, closed, open }

  private var status: Status {
    switch day {
    case .unknown: .unknown
    case .closed: .closed
    case .open: .open
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(weekday.label)
        Spacer()
        Menu {
          Button("Unknown") { setStatus(.unknown) }
          Button("Closed") { setStatus(.closed) }
          Button("Open") { setStatus(.open) }
        } label: {
          Text(statusLabel)
            .font(.callout)
            .foregroundStyle(status == .unknown ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
      }
      if case let .open(periods) = day {
        ForEach(periods.indices, id: \.self) { index in
          ServicePeriodRow(
            period: Binding(
              get: { periods[index] },
              set: { updatePeriod(at: index, to: $0) }
            ),
            onDelete: { deletePeriod(at: index) }
          )
        }
        Button { addPeriod() } label: {
          Label("Add sitting", systemImage: "plus.circle")
            .font(.caption)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var statusLabel: String {
    switch status {
    case .unknown: "Unknown"
    case .closed: "Closed"
    case .open: openSummary
    }
  }

  /// "Open" or a compact meal/times summary when the day has sittings.
  private var openSummary: String { day.display }

  private func setStatus(_ newStatus: Status) {
    switch newStatus {
    case .unknown: day = .unknown
    case .closed: day = .closed
    case .open:
      if case .open = day { return }
      day = .open([])
    }
  }

  private func addPeriod() {
    guard case let .open(periods) = day else { return }
    day = .open(periods + [ServicePeriod(interval: OpenInterval(open: 12 * 60, close: 14 * 60))])
  }

  /// Replace a sitting, pruning it if the edit left it empty (no meal, no times) —
  /// the `ServicePeriod` invariant. A day with no remaining sittings stays open.
  private func updatePeriod(at index: Int, to period: ServicePeriod) {
    guard case let .open(periods) = day, periods.indices.contains(index) else { return }
    var updated = periods
    if period.meal == nil && period.interval == nil {
      updated.remove(at: index)
    } else {
      updated[index] = period
    }
    day = .open(updated)
  }

  private func deletePeriod(at index: Int) {
    guard case let .open(periods) = day, periods.indices.contains(index) else { return }
    var updated = periods
    updated.remove(at: index)
    day = .open(updated)
  }
}

/// One service sitting: a meal Menu and an optional opens/closes clock pair.
private struct ServicePeriodRow: View {
  @Binding var period: ServicePeriod
  var onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        Button("No meal") { period.meal = nil }
        ForEach(Meal.allCases, id: \.self) { meal in
          Button(meal.label) { period.meal = meal }
        }
      } label: {
        Text(period.meal?.label ?? "Any meal")
          .font(.caption)
      }
      Spacer()
      if period.interval != nil {
        clockPicker(
          minute: Binding(get: { period.interval?.open ?? 0 }, set: { setOpen($0) })
        )
        Text("–").foregroundStyle(.secondary)
        clockPicker(
          minute: Binding(get: { normalizedClose }, set: { setClose($0) })
        )
        Button { period.interval = nil } label: {
          Image(systemName: "clock.badge.xmark")
        }
        .buttonStyle(.borderless)
      } else {
        Button("Add times") {
          period.interval = OpenInterval(open: 12 * 60, close: 14 * 60)
        }
        .font(.caption)
      }
      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
    }
  }

  /// The close clock as a wall-clock minute (past-midnight closes store as +24h).
  private var normalizedClose: Int { (period.interval?.close ?? 0) % (24 * 60) }

  private func setOpen(_ minute: Int) {
    guard var interval = period.interval else { return }
    interval.open = minute
    // Keep close after open; a close at/under open reads as past-midnight (+24h).
    if interval.close <= interval.open { interval.close += 24 * 60 }
    period.interval = interval
  }

  private func setClose(_ wallMinute: Int) {
    guard var interval = period.interval else { return }
    interval.close = wallMinute <= interval.open ? wallMinute + 24 * 60 : wallMinute
    period.interval = interval
  }

  private func clockPicker(minute: Binding<Int>) -> some View {
    DatePicker(
      "",
      selection: Binding(
        get: { Self.date(fromMinute: minute.wrappedValue) },
        set: { minute.wrappedValue = Self.minute(from: $0) }
      ),
      displayedComponents: .hourAndMinute
    )
    .labelsHidden()
  }

  private static let referenceDate = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 0))

  private static func date(fromMinute minute: Int) -> Date {
    let clamped = ((minute % (24 * 60)) + 24 * 60) % (24 * 60)
    return Calendar.current.date(
      bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: referenceDate
    ) ?? referenceDate
  }

  private static func minute(from date: Date) -> Int {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
  }
}
