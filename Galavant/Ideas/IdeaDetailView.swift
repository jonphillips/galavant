import GalavantSchema
import MapKit
import SwiftUI

/// The placement of an idea on the trip's itinerary — populated only when the
/// detail is drilled into from the **Itinerary** (a scheduled stop), nil for a
/// plain pool idea. Drives the "On the Itinerary" section.
struct StopDetailContext {
  /// "Day 2 · Wed, Jun 17" (dated) / "Day 2" (undated) / "To Be Scheduled".
  let dayLabel: String
  let schedule: Schedule
}

/// A read-only look at an idea — its location on a map, its place on the
/// itinerary (for a scheduled stop), kind, region, link, his/hers interest, tags,
/// and notes. Drilled into *within the planning panel* (the Trip Ideas list by row
/// tap, the Itinerary by the row's info button) so it never covers the map; the
/// host (`TripDetailContent`) supplies the back header + title around this content.
/// The host also resolves the tag names, interests, and stop context; this view is
/// pure presentation. (The Itinerary one may become a full-screen push later when
/// a stop earns yet-richer context — travel time, hours, booking; docs/BACKLOG.md.)
struct IdeaDetailView: View {
  let idea: Idea
  let tagNames: [String]
  let interests: [(planner: Planner, level: Interest)]
  /// Set when this is a scheduled itinerary stop (vs. a plain pool idea).
  var stopContext: StopDetailContext? = nil

  /// The link as a URL, if it parses — drives the tappable Link row.
  private var link: URL? {
    guard !idea.url.isEmpty else { return nil }
    return URL(string: idea.url)
  }

  /// An Apple Maps handoff URL for the stop's coordinate (named), or nil when the
  /// idea has no location. A URL (not `MKMapItem.openInMaps`) so it reads as a
  /// tappable row and dodges MapKit's beta API churn (CLAUDE.md).
  private var mapsURL: URL? {
    guard let coordinate = idea.coordinate,
      var components = URLComponents(string: "https://maps.apple.com/")
    else { return nil }
    components.queryItems = [
      URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
      URLQueryItem(name: "q", value: idea.name.isEmpty ? "Pinned location" : idea.name),
    ]
    return components.url
  }

  var body: some View {
    List {
      if let coordinate = idea.coordinate {
        Section {
          StopMap(coordinate: coordinate, name: idea.name)
            .frame(height: 170)
            .listRowInsets(EdgeInsets())
          if let mapsURL {
            Link(destination: mapsURL) {
              Label("Open in Maps", systemImage: Icon.map.systemName)
            }
          }
        }
      }

      Section { header }

      if let stopContext {
        Section("On the Itinerary") { placement(stopContext) }
      }

      if let link {
        Section {
          Link(destination: link) {
            Label(link.host() ?? idea.url, systemImage: "link").lineLimit(1)
          }
        }
      }

      if !interests.isEmpty {
        Section("Interest") {
          ForEach(interests, id: \.planner.id) { entry in
            HStack {
              Text(entry.planner.displayName)
              Spacer()
              InterestView(interest: entry.level)
            }
          }
        }
      }

      if !tagNames.isEmpty {
        Section("Tags") {
          ForEach(tagNames, id: \.self) { name in
            Label(name, systemImage: Icon.tag.systemName)
          }
        }
      }

      if !idea.notes.isEmpty {
        Section("Notes") { Text(idea.notes) }
      }

      if idea.visited {
        Section {
          Label("Visited", systemImage: Icon.checkmark.systemName)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// The kind icon, the kind label, and the region — the at-a-glance identity.
  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .font(.title)
        .foregroundStyle(.tint)
        .frame(width: 40)
      VStack(alignment: .leading, spacing: 4) {
        if let kind = idea.kind {
          Text(kind.label).foregroundStyle(.secondary)
        }
        if let address = idea.address, !address.isEmpty {
          Label(address, systemImage: Icon.location.systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if let regionName = idea.regionName, !regionName.isEmpty {
          Label(regionName, systemImage: Icon.location.systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if let phone = idea.phone, !phone.isEmpty {
          if let telURL = telURL {
            Link(destination: telURL) {
              Label(phone, systemImage: "phone").font(.subheadline)
            }
          } else {
            Label(phone, systemImage: "phone")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  /// A `tel:` URL for the stored phone number (digits/`+` only), or nil.
  private var telURL: URL? {
    guard let phone = idea.phone else { return nil }
    let digits = phone.filter { $0.isNumber || $0 == "+" }
    return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
  }

  /// Where the stop sits on the itinerary: its day + time, or the dayless bucket.
  @ViewBuilder private func placement(_ context: StopDetailContext) -> some View {
    if context.schedule.dayNumber == nil {
      Label("To Be Scheduled", systemImage: Icon.toBeScheduled.systemName)
    } else {
      LabeledContent("Day", value: context.dayLabel)
      LabeledContent("Time", value: context.schedule.display)
    }
  }
}

/// A static thumbnail map centred on a stop's pin — non-interactive so it reads as
/// a header image and never steals the surrounding list's scroll.
private struct StopMap: View {
  let coordinate: CLLocationCoordinate2D
  let name: String

  var body: some View {
    Map(
      initialPosition: .region(
        MKCoordinateRegion(
          center: coordinate,
          span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
    ) {
      Marker(name.isEmpty ? "Stop" : name, coordinate: coordinate)
    }
    .allowsHitTesting(false)
  }
}
