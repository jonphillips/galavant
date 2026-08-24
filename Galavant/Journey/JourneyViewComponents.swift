import Foundation
import GalavantSchema
import SwiftUI
import UIKit

struct JourneySummaryHeader: View {
  let trip: Trip?
  let summary: JourneyProjection.TripSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(trip?.name ?? "Journey")
        .font(.largeTitle.bold())
      Text(
        "\(summary.startDate.formatted(date: .abbreviated, time: .omitted)) – "
          + "\(summary.endDate.formatted(date: .abbreviated, time: .omitted))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Label("\(summary.nightCount) nights", systemImage: "moon.stars")
        Text("·")
        Label("\(summary.stayCount) stays", systemImage: Icon.stay.systemName)
        if summary.transferDayCount > 0 {
          Text("·")
          Label {
            Text(
              summary.transferDayCount == 1
                ? "1 transfer day" : "\(summary.transferDayCount) transfer days")
          } icon: {
            Image(systemName: TransportMode.driving.systemImageName)
          }
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      if !summary.regionNames.isEmpty {
        Text(regionSummary)
          .font(.subheadline)
          .foregroundStyle(.tint)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(trip?.name ?? "Journey"), \(summary.nightCount) nights, \(summary.stayCount) stays")
  }

  /// The locality run, capped so a long multi-region trip never overflows the
  /// header — the map and day spine carry the full geography.
  private var regionSummary: String {
    let shown = summary.regionNames.prefix(3)
    let overflow = summary.regionNames.count - shown.count
    return shown.joined(separator: " · ") + (overflow > 0 ? " · +\(overflow) more" : "")
  }
}

struct JourneyStayRail: View {
  let projection: JourneyProjection
  @Binding var selection: JourneySelection?

  private var bands: [JourneyProjection.StayBand] {
    projection.stayBands.filter { !$0.nights.isEmpty }
  }

  var body: some View {
    if !bands.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Where you’ll stay")
          .font(.headline)
          .padding(.horizontal)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 10) {
            ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
              JourneyStayChip(
                band: band,
                color: StayPalette.color(forStay: index),
                isSelected: selection == .stay(band.id))
              .contentShape(RoundedRectangle(cornerRadius: 12))
              .onTapGesture { toggle(band.id) }
            }
          }
          .padding(.horizontal)
        }
      }
    }
  }

  private func toggle(_ id: TripStay.ID) {
    selection = selection == .stay(id) ? nil : .stay(id)
  }
}

/// A stay's colour, shared by its "Where you'll stay" chip and its numbered map
/// pin so a lodging reads as one colour across the surface. Reuses `DayPalette`'s
/// distinct cycle, keyed by stay order rather than day.
enum StayPalette {
  static func color(forStay index: Int) -> Color {
    DayPalette.colors[((index % DayPalette.colors.count) + DayPalette.colors.count)
      % DayPalette.colors.count]
  }
}

struct JourneyStayChip: View {
  let band: JourneyProjection.StayBand
  let color: Color
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label {
        Text(headline)
          .font(.caption.weight(.semibold))
      } icon: {
        Image(systemName: Icon.stay.systemName)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      Text(band.title)
        .font(.caption2)
        .lineLimit(2)
        .opacity(0.9)
    }
    .frame(width: 190, alignment: .leading)
    .frame(minHeight: 52, alignment: .topLeading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .foregroundStyle(.white)
    .background(color.gradient, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.white, lineWidth: isSelected ? 3 : 0)
    }
    .shadow(color: isSelected ? color.opacity(0.5) : .clear, radius: 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(band.regionName ?? band.title), \(band.nightCount) nights")
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  private var headline: String {
    let nights = "\(band.nightCount) night\(band.nightCount == 1 ? "" : "s")"
    return band.regionName.map { "\($0) · \(nights)" } ?? nights
  }
}

struct JourneyDaySpine: View {
  let projection: JourneyProjection
  let model: JourneyModel
  @Binding var selection: JourneySelection?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      Text("The trip")
        .font(.headline)
      ForEach(projection.days) { day in
        JourneyDayCard(
          day: day,
          model: model,
          isSelected: selection == .day(day.dayNumber))
        .id(day.dayNumber)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { toggle(day.dayNumber) }
      }
    }
  }

  private func toggle(_ dayNumber: Int) {
    selection = selection == .day(dayNumber) ? nil : .day(dayNumber)
  }
}

struct JourneyDayCard: View {
  let day: JourneyProjection.DaySummary
  let model: JourneyModel
  let isSelected: Bool

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Day \(day.dayNumber)")
          .font(.headline)
        Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        if let locality = day.locality {
          Text(locality)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tint)
        }
        if !day.stops.isEmpty { disclosureChevron }
      }

      if day.stops.isEmpty {
        Text(day.locality != nil ? "At leisure" : "A quiet day")
          .foregroundStyle(.secondary)
      } else if isExpanded {
        // Expanded: the day's stops in order, each with its header image.
        VStack(alignment: .leading, spacing: 8) {
          ForEach(day.stops) { stop in
            JourneyStopRow(stop: stop, thumbnail: model.thumbnail(forIdea: stop.ideaID))
          }
        }
      } else {
        Text(day.stopTitles.joined(separator: "  ·  "))
          .font(.body)
          .lineLimit(2)
        if let definingStop = day.definingStop, day.stopCount > 1,
          definingStop.title != day.stopTitles.first {
          Text("Defining stop: \(definingStop.title)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if let transfer = day.lodgingChangeover {
        HStack(spacing: 6) {
          Image(systemName: transfer.mode.systemImageName)
          Text("\(transfer.from.title) → \(transfer.to.title)")
          if let time = transfer.travelTime {
            Text("· \(time.formatted(mode: transfer.mode))")
          }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12), in: Capsule())
      }

      if !day.weatherAnchors.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(day.weatherAnchors.enumerated()), id: \.offset) { index, _ in
            if let weather = model.summary(for: day.dayNumber, anchorIndex: index) {
              JourneyWeatherBadge(summary: weather)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(
          isSelected ? Color.accentColor : Color.gray.opacity(0.25),
          lineWidth: isSelected ? 2 : 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(dayAccessibilityLabel)
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  /// The expand/collapse control for a day's stops. Its own button, so tapping it
  /// reveals the itinerary rows without also toggling the card's map selection.
  private var disclosureChevron: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
    } label: {
      Image(systemName: "chevron.right")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .contentShape(Rectangle())
        .padding(.leading, 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isExpanded ? "Hide stops" : "Show stops")
  }

  private var dayAccessibilityLabel: String {
    var pieces = ["Day \(day.dayNumber)"]
    if let locality = day.locality { pieces.append(locality) }
    if day.stopCount > 0 { pieces.append("\(day.stopCount) stops") }
    if day.hasLodgingChangeover { pieces.append("transfer day") }
    return pieces.joined(separator: ", ")
  }
}

/// One stop inside an expanded day card: its header image (or kind glyph) beside
/// the title and kind. The same 44-pt fit-not-fill footprint the Ideas list uses,
/// so a letterboxed logo never crops to an unreadable zoom.
struct JourneyStopRow: View {
  let stop: JourneyProjection.StopDigest
  let thumbnail: Data?

  var body: some View {
    HStack(spacing: 10) {
      leadingImage
      VStack(alignment: .leading, spacing: 1) {
        Text(stop.title)
          .font(.subheadline)
          .lineLimit(2)
        if let kind = stop.kind {
          Text(kind.label)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var leadingImage: some View {
    if let thumbnail, let image = UIImage(data: thumbnail) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      Image(systemName: stop.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }
}

struct JourneyWeatherBadge: View {
  let summary: WeatherSummary
  @State private var isShowingDetail = false

  var body: some View {
    Button {
      isShowingDetail = true
    } label: {
      Group {
        if let daily = summary.daily {
          Label {
            Text("\(daily.highTemperature, format: .measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))) / \(daily.lowTemperature, format: .measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))")
          } icon: {
            Image(systemName: daily.symbolName)
          }
        } else if let current = summary.current {
          Label {
            Text(current.temperature, format: .measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
          } icon: {
            Image(systemName: current.symbolName)
          }
        }
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.quaternary, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Weather forecast")
    .accessibilityHint("Shows weather details.")
    .popover(isPresented: $isShowingDetail) {
      WeatherDetailView(summary: summary)
    }
  }
}
