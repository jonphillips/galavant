import GalavantSchema
import SwiftUI

/// A read-only look at an idea — its kind, region, link, his/hers interest, tags,
/// and notes. Drilled into *within the planning panel* (the Trip Ideas list by row
/// tap, the Itinerary by the row's info button) so it never covers the map; the
/// host (`TripDetailContent`) supplies the back header + title around this content.
/// The host also resolves the tag names and interests; this view is pure
/// presentation. Sparse now, it grows as the Idea model fills out. (The Itinerary
/// one may become a full-screen push later when a stop earns richer per-stop
/// context — see docs/BACKLOG.md.)
struct IdeaDetailView: View {
  let idea: Idea
  let tagNames: [String]
  let interests: [(planner: Planner, level: Interest)]

  /// The link as a URL, if it parses — drives the tappable Link row.
  private var link: URL? {
    guard !idea.url.isEmpty else { return nil }
    return URL(string: idea.url)
  }

  var body: some View {
    List {
      Section { header }

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
        if let regionName = idea.regionName, !regionName.isEmpty {
          Label(regionName, systemImage: Icon.location.systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }
}
