import GalavantSchema
import SwiftUI
import UIKit

struct RegionGuideCardRow: View {
  let card: RegionGuide.Card
  let headerThumbnail: Data?
  let plannerNames: [Planner.ID: String]
  let badge: String?
  let rank: ChatRank?
  let isFocused: Bool
  let onTap: () -> Void
  var putInTitle: String? = nil
  var onPutHere: (() -> Void)? = nil

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 12) {
          if let headerThumbnail, let image = UIImage(data: headerThumbnail) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 70, height: 70)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          VStack(alignment: .leading, spacing: 5) {
            Text(card.idea.name).font(.headline)
            let address = card.idea.address.flatMap { $0.isEmpty ? nil : $0 }
            if let locality = address ?? card.idea.regionName, !locality.isEmpty {
              Text(locality).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if card.emphasis == .notesFirst, let note = card.latestNote { noteText(note, lines: 2) }
            if let accolade = card.accolade {
              Text("\(accolade.sourceName) · \(accolade.nativeDisplay)").font(.subheadline)
            }
            if card.emphasis == .accoladesFirst, let note = card.latestNote { noteText(note, lines: 1) }
            HStack(spacing: 10) {
              ForEach(card.interests, id: \.planner.id) { entry in
                Text("\(entry.planner.displayName): \(entry.level?.label ?? "Not rated")")
                  .font(.caption).foregroundStyle(.secondary)
              }
              if card.idea.visited {
                Label("Visited", systemImage: Icon.checkmark.systemName)
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        if badge != nil || rank != nil {
          HStack(spacing: 6) {
            if let badge {
              Text(badge).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
            }
            if let rank {
              RankMedal(priority: rank.priority, priorityOutOf: rank.priorityOutOf, listName: rank.list)
              if let list = rank.list {
                Text(list).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
          }
        }
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(isFocused ? Color.accentColor.opacity(0.15) : nil)
    .accessibilityElement(children: .combine)
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      if let onPutHere {
        Button(action: onPutHere) {
          Label("Put here", systemImage: "calendar.badge.plus")
        }
        .tint(.accentColor)
      }
    }
    .contextMenu {
      if let putInTitle, let onPutHere {
        Button(putInTitle, systemImage: "calendar.badge.plus", action: onPutHere)
      }
    }
  }

  private func noteText(_ note: TasteNote, lines: Int) -> some View {
    let who = note.plannerID.flatMap { plannerNames[$0] } ?? "Both of us"
    let firstLine = note.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? note.body
    return Text("\(firstLine) · \(who)").font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
  }
}
