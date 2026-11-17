import GalavantSchema
import SwiftUI
import UIKit

struct RegionGuideCardRow: View {
  let card: RegionGuide.Card
  let headerThumbnail: Data?
  let plannerNames: [Planner.ID: String]
  let badge: String?
  let rank: ChatRank?
  var listRank: TripIdea.RankedList.Member? = nil
  let isFocused: Bool
  let onTap: () -> Void
  var putInTitle: String? = nil
  var onPutHere: (() -> Void)? = nil

  private var medalRank: ChatRank? {
    guard let rank,
      ChatRankMedal.tier(priority: rank.priority, priorityOutOf: rank.priorityOutOf) != nil
    else { return nil }
    return rank
  }

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
        if badge != nil || medalRank != nil || listRank != nil {
          HStack(spacing: 6) {
            if let badge {
              Text(badge).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
            }
            if let listRank {
              if listRank.isOpenChoice,
                ChatRankMedal.tier(priority: listRank.priority, priorityOutOf: listRank.priorityOutOf) != nil
              {
                RankMedal(priority: listRank.priority, priorityOutOf: listRank.priorityOutOf)
              } else {
                Text(listRank.priority.formatted())
                  .font(.caption2.weight(.bold))
                  .monospacedDigit()
                  .frame(width: 18, height: 18)
                  .overlay { Circle().strokeBorder(.secondary, lineWidth: 1) }
                  .accessibilityLabel("Chat's \(Self.ordinal(listRank.priority)) choice")
                  .accessibilityAddTraits(.isStaticText)
              }
            } else if let rank = medalRank {
              RankMedal(priority: rank.priority, priorityOutOf: rank.priorityOutOf, listName: rank.list)
              if let list = rank.list {
                Text(list)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .accessibilityHidden(true)
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

  private static func ordinal(_ value: Int) -> String {
    let suffix: String
    switch value % 100 {
    case 11...13: suffix = "th"
    default:
      switch value % 10 {
      case 1: suffix = "st"
      case 2: suffix = "nd"
      case 3: suffix = "rd"
      default: suffix = "th"
      }
    }
    return "\(value)\(suffix)"
  }

  private func noteText(_ note: TasteNote, lines: Int) -> some View {
    let who = note.plannerID.flatMap { plannerNames[$0] } ?? "Both of us"
    let firstLine = note.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? note.body
    return Text("\(firstLine) · \(who)").font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
  }
}
