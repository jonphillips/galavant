import GalavantSchema
import SwiftUI

/// The leading glyph a `PlanningRow` shows. `.kind` (the default) is the idea's
/// category icon — what every pool/shortlist/Add-Ideas row wears. `.sequence`
/// draws a day-coloured `SequencePin`, used only by the day-itinerary timeline so
/// a located stop's row number matches its map pin (the unlocated rows there stay
/// on `.kind`, since they have no pin).
enum PlanningRowMarker {
  case kind
  case sequence(Int, Color)
}

/// A planning-screen row: a leading marker, a name/subtitle, and a caller-supplied
/// trailing control. Shared by the Ideas list, the Itinerary, and the
/// Add-Ideas sheet. Accepts a `StopContent` directly (for any itinerary stop,
/// idea-backed or freeform) or an `Idea` convenience init (for the pool sheet).
struct PlanningRow<Trailing: View>: View {
  /// What the subtitle line carries. Inside a (single-destination) trip the city
  /// is redundant, so the Itinerary and Trip Ideas tab show the **category**
  /// instead (signal, not the city context already supplies); the Add-Ideas
  /// sheet browses the wider regional pool, where the city still disambiguates.
  enum Subtitle { case region, category }

  let content: StopContent
  var title: String?
  var subtitle: Subtitle = .region
  /// The leading glyph — the kind icon by default; the day itinerary passes a
  /// `.sequence` to mirror the map pins.
  var marker: PlanningRowMarker = .kind
  @ViewBuilder var trailing: Trailing

  init(
    content: StopContent,
    title: String? = nil,
    subtitle: Subtitle = .region,
    marker: PlanningRowMarker = .kind,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.content = content
    self.title = title
    self.subtitle = subtitle
    self.marker = marker
    self.trailing = trailing()
  }

  init(idea: Idea, subtitle: Subtitle = .region, @ViewBuilder trailing: () -> Trailing) {
    self.content = .idea(idea)
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  private var subtitleText: String? {
    switch subtitle {
    case .region: content.idea?.regionName.flatMap { $0.isEmpty ? nil : $0 }
    case .category: content.idea?.kind?.label
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      leadingMarker
      VStack(alignment: .leading, spacing: 2) {
        Text(title ?? content.title)
        if let subtitleText {
          Text(subtitleText).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer()
      trailing
    }
    .padding(.vertical, 2)
  }

  /// The kind icon (default), or a day-coloured `SequencePin` matching the stop's
  /// map pin. Both occupy a 26-wide slot so the title column stays aligned whether
  /// a row carries a number or an icon.
  @ViewBuilder private var leadingMarker: some View {
    switch marker {
    case .kind:
      Image(systemName: content.idea?.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 26)
        .padding(.top, 2)
    case let .sequence(number, color):
      SequencePin(number: number, color: color)
        .frame(width: 26)
    }
  }
}

/// "Day 3" for an undated trip, "Day 3 · Wed, Jun 17" once it's dated — shared by
/// the day headers, the Move-to-Day menu, and the Add-Stop sheet.
func dayLabel(_ number: Int, trip: Trip?) -> String {
  guard let date = trip?.date(forDay: number) else { return "Day \(number)" }
  return "Day \(number) · "
    + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

/// Compact day label for the chip strip: "M 8/24" on a dated trip, "Day N"
/// when undated. The ambiguous Tuesday/Thursday and Saturday/Sunday initials
/// expand to two letters while the other weekdays stay at one.
func dayChipLabel(_ number: Int, trip: Trip?) -> String {
  guard let date = trip?.date(forDay: number) else { return "Day \(number)" }
  let weekday = switch Calendar.current.component(.weekday, from: date) {
  case 1: "Su"
  case 2: "M"
  case 3: "Tu"
  case 4: "W"
  case 5: "Th"
  case 6: "F"
  case 7: "Sa"
  default: ""
  }
  let monthDay = date.formatted(.dateTime.month(.defaultDigits).day())
  return "\(weekday) \(monthDay)"
}

struct AlternativeSlotControls: View {
  let model: TripPlanningModel
  let ring: ResolvedAlternativeRing

  var body: some View {
    HStack(spacing: 8) {
      Button {
        model.cycleAlternativeButtonTapped(ring.activeMember.id)
      } label: {
        Icon.cycleAlternative.image
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Cycle alternatives")
      Button {
        model.toggleAlternativeDisclosure(ring.groupID)
      } label: {
        HStack(spacing: 4) {
          Text("\(ring.activeIndex + 1) of \(ring.members.count)")
          Icon.disclosure.image
            .rotationEffect(.degrees(model.isAlternativeDisclosureExpanded(ring.groupID) ? 90 : 0))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("\(ring.members.count) alternatives")
      .accessibilityValue(model.isAlternativeDisclosureExpanded(ring.groupID) ? "Expanded" : "Collapsed")
    }
  }
}

struct AlternativeSlotDisclosure: View {
  let model: TripPlanningModel
  let ring: ResolvedAlternativeRing

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(ring.members) { member in
        alternativeRow(member)
      }
      Button("Add Alternative", systemImage: Icon.addInline.systemName) {
        model.addAlternativeButtonTapped(to: ring.activeMember.id)
      }
      .buttonStyle(.borderless)
    }
    .padding(.leading, 38)
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private func alternativeRow(_ member: ResolvedStop) -> some View {
    HStack(spacing: 10) {
      Button {
        model.alternativeButtonTapped(member.id)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: member.idea?.kind?.systemImage ?? "mappin.and.ellipse")
            .foregroundStyle(
              member.id == ring.activeMember.id
                ? AnyShapeStyle(.tint)
                : AnyShapeStyle(.secondary))
          Text(member.content.title)
            .foregroundStyle(.primary)
          Spacer()
          if member.id == ring.activeMember.id {
            Icon.checkmark.image
              .foregroundStyle(.tint)
              .accessibilityLabel("Current choice")
          }
        }
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(
        member.id == ring.activeMember.id
          ? "Current alternative, \(member.content.title)"
          : "Choose \(member.content.title)")
      Button {
        model.promoteAlternativeButtonTapped(member.id)
      } label: {
        Icon.promoteAlternative.image
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Promote \(member.content.title) to its own itinerary stop")
      Button(role: .destructive) {
        model.remove(member.id)
      } label: {
        Icon.remove.image
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove \(member.content.title) from alternatives")
    }
    .padding(.vertical, 2)
  }
}
