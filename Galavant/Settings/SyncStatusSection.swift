import CloudSyncKit
import SwiftUI

/// The sync-health row at the top of Settings (docs/M5-EXECUTION.md → M5-sync, slice
/// 3): a colored dot + one line saying whether CloudKit sync is live, local-only, or
/// broken — tappable to a small detail with the reason, pending count, and a "Try
/// again". When the gate is off, the row is the enable affordance.
struct SyncStatusSection: View {
  let model: SyncHealthModel
  @State private var showingDetail = false

  var body: some View {
    Section {
      Button {
        showingDetail = true
      } label: {
        HStack(spacing: 12) {
          SyncStatusDot(status: model.displayStatus)
          Text(model.displayStatus.summary)
            .foregroundStyle(.primary)
          Spacer(minLength: 8)
          Icon.disclosure.image
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
    } header: {
      Text("Sync")
    }
    .sheet(isPresented: $showingDetail) {
      SyncStatusDetailView(model: model)
    }
  }
}

/// The colored dot — the one glanceable "is sync healthy?" signal. Color is pure
/// presentation, so it lives here rather than on the domain-free `SyncDisplayStatus`.
private struct SyncStatusDot: View {
  let status: SyncDisplayStatus

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 10, height: 10)
      .accessibilityHidden(true)
  }

  private var color: Color {
    switch status {
    case .disabled: .secondary
    case .localOnly: .orange
    case .syncing, .downloading: .blue
    case .upToDate: .green
    case .error: .red
    }
  }
}

/// The tap-through detail: the human summary, the reason / pending count, and the
/// primary action — "Turn on sync" when the gate is off, "Try again" otherwise.
struct SyncStatusDetailView: View {
  let model: SyncHealthModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Status", value: model.displayStatus.summary)
          if let detail = detailLine {
            LabeledContent("Details", value: detail)
          }
        } footer: {
          Text(explanation)
        }

        Section {
          Button {
            Task { await primaryAction() }
          } label: {
            HStack {
              Text(primaryActionTitle)
              if model.isStarting {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(model.isStarting)
        }
      }
      .navigationTitle("Sync")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  /// The reason string / pending count, when there is one to show.
  private var detailLine: String? {
    switch model.displayStatus {
    case let .localOnly(reason): reason
    case let .syncing(pending): "\(pending) change\(pending == 1 ? "" : "s") uploading"
    case .downloading: "Downloading changes from iCloud"
    case let .error(message): message
    case .disabled, .upToDate: nil
    }
  }

  private var explanation: String {
    switch model.displayStatus {
    case .disabled:
      "Sync is off, so your ideas and trips stay on this device. Turn it on to share the same pool with your travel party over iCloud."
    case .localOnly:
      "Changes stay on this device until iCloud can sync. You and your travel party won’t see each other’s updates yet."
    case .syncing:
      "Uploading recent changes to iCloud."
    case .downloading:
      "Downloading changes from iCloud. A first sync of a large pool can take a while — iCloud drip-feeds it and it will finish on its own; keep this device on Wi-Fi and power."
    case .upToDate:
      "Your ideas and trips are synced with your travel party over iCloud."
    case .error:
      "Sync hit an error. Try again — if it persists, check your iCloud account and network."
    }
  }

  private var primaryActionTitle: String {
    switch model.displayStatus {
    case .disabled: "Turn on iCloud sync"
    default: "Try again"
    }
  }

  private func primaryAction() async {
    switch model.displayStatus {
    case .disabled: await model.enableSyncButtonTapped()
    default: await model.tryAgainButtonTapped()
    }
  }
}
