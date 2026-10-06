import CloudSyncKit
import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import UniformTypeIdentifiers

/// The "You"/settings section, surfaced as a top-level destination in the sidebar /
/// tab bar (ADR-0014 slice 4 graduates here from the Ideas toolbar stub). Houses the
/// sync-health surface (ADR/M5-sync), the AI/chat model settings, and travel-party
/// sharing.
///
/// No `NavigationStack` of its own: the `AppContainer` detail column already provides
/// one (nesting another traps the split view — see the iPad nested-stack note).
struct SettingsScreen: View {
  @State private var model = SettingsModel()
  @State private var syncHealth = SyncHealthModel()
  @State private var backupExport = DatabaseBackupExportModel(
    configuration: GalavantCloudSync.databaseBackupConfiguration
  )
  @State private var backupRestore = DatabaseBackupRestoreModel(
    configuration: GalavantCloudSync.databaseBackupConfiguration
  )
  @State private var backupExportDocument: GalavantBackupExportDocument?
  @State private var backupExportFilename = "Galavant-Backup.sqlite"
  @State private var isPresentingBackupExporter = false
  @State private var isPresentingBackupImporter = false
  @State private var isConfirmingRestore = false
  @State private var isPresentingRestoreRestartCover = false
  @State private var backupOwnership: Bool?
  @State private var backupOwnershipCheckFailed = false
  @Dependency(\.defaultDatabase) private var database
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Form {
      // Above Sharing so "am I actually syncing?" is the first thing Settings answers
      // — silent degradation is fine for dev, not for two-person use (M5-sync).
      SyncStatusSection(model: syncHealth)

      AISettingsSections()

      Section("Library") {
        NavigationLink {
          RegionManagementSettingsView()
        } label: {
          Icon.map.label("Map Regions")
        }
        NavigationLink {
          PlannerManagementView()
        } label: {
          Icon.travelParty.label("Planners")
        }
      }

      Section {
        Button {
          Task { await model.shareTravelPartyButtonTapped() }
        } label: {
          Icon.travelParty.label("Share Travel Party")
        }
      } header: {
        Text("Travel Party")
      } footer: {
        Text("Invite your travel party to share the same ideas, trips, and ratings over iCloud.")
      }

      backupSection

      #if DEBUG
      Section("Developer") {
        NavigationLink {
          WeatherDebugView()
        } label: {
          Label("Weather Test", systemImage: "sun.max")
        }
      }
      #endif
    }
    .navigationTitle("Settings")
    .sheet(item: $model.sharedRecord) { sharedRecord in
      CloudSharingView(sharedRecord: sharedRecord)
    }
    // Refresh the sync signals on appear, on scene activation (the same hook that
    // drives the pending-change redrain), and on cross-process DB changes.
    .task { await syncHealth.refresh() }
    .task {
      for await _ in DatabaseChange.notifications {
        await syncHealth.refresh()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await syncHealth.refresh() }
    }
    // When a sync cycle finishes (the engine's observable activity flips), re-read the
    // pending count so "Syncing…" clears to "Up to date" as changes drain.
    .onChange(of: syncHealth.isSynchronizing) { _, _ in
      Task { await syncHealth.refresh() }
    }
    .task { await refreshBackupOwnership() }
    .fileExporter(
      isPresented: $isPresentingBackupExporter,
      document: backupExportDocument,
      contentType: .galavantSQLiteBackup,
      defaultFilename: backupExportFilename,
      onCompletion: backupExportCompleted,
      onCancellation: clearPreparedBackup
    )
    .fileImporter(
      isPresented: $isPresentingBackupImporter,
      allowedContentTypes: [.galavantSQLiteBackup],
      onCompletion: backupRestoreSelected
    )
    .alert("Restore This Backup?", isPresented: $isConfirmingRestore) {
      Button("Restore", role: .destructive) {
        Task {
          if await backupRestore.restorePreparedBackup() {
            isPresentingRestoreRestartCover = true
          }
        }
      }
      Button("Cancel", role: .cancel) { backupRestore.discardPreparedRestore() }
    } message: {
      Text(restoreConfirmation)
    }
    .fullScreenCover(isPresented: $isPresentingRestoreRestartCover) {
      ContentUnavailableView(
        "Restart Galavant",
        systemImage: "arrow.clockwise",
        description: Text("Your backup is restored — close and reopen Galavant to use it. You can undo this restore from Settings after reopening. iCloud sync stays off until you turn it back on.")
      )
      .interactiveDismissDisabled()
    }
    .alert("Could Not Export Backup", isPresented: backupExportErrorPresented) {
      Button("OK") { backupExport.dismissError() }
    } message: {
      Text(backupExport.errorMessage ?? "")
    }
    .alert("Could Not Restore Backup", isPresented: backupRestoreErrorPresented) {
      Button("OK") { backupRestore.dismissError() }
    } message: {
      Text(backupRestore.errorMessage ?? "")
    }
  }

  @ViewBuilder private var backupSection: some View {
    if backupOwnership == true {
      Section("Backup") {
        Text("Backups are made by the person who shared this travel party with you.")
      }
    } else if backupOwnershipCheckFailed {
      Section("Backup") {
        Text("Galavant couldn't check who owns this travel party. Backups are unavailable right now.")
      }
    } else if backupOwnership == false {
      Section("Backup") {
        Button {
          Task {
            guard let snapshot = await backupExport.prepareBackupForExport() else { return }
            backupExportDocument = GalavantBackupExportDocument(snapshot: snapshot)
            backupExportFilename = backupExport.defaultFilename()
            isPresentingBackupExporter = true
          }
        } label: {
          Label("Export a Backup", systemImage: "externaldrive.badge.checkmark")
        }
        .disabled(backupExport.isPreparing)

        Button { isPresentingBackupImporter = true } label: {
          HStack {
            Label("Restore from a Backup", systemImage: "externaldrive.badge.plus")
            if backupRestore.isPreparing || backupRestore.isRestoring {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(backupRestore.isPreparing || backupRestore.isRestoring)

        if backupRestore.hasUndoableRestore {
          Button {
            Task {
              await backupRestore.prepareUndo()
              isConfirmingRestore = backupRestore.isPrepared
            }
          } label: {
            Label("Undo Last Restore", systemImage: "arrow.uturn.backward")
          }
          .disabled(backupRestore.isPreparing || backupRestore.isRestoring)
        }
      }
    } else {
      Section("Backup") { ProgressView() }
    }
  }

  private var restoreConfirmation: String {
    var message = "This replaces the library on this device. Galavant saves an automatic undo backup first. iCloud sync stays off until you turn it back on. When you do, this restored library becomes the version everywhere: it overwrites iCloud, and anything deleted since the backup comes back."
    if backupRestore.willNeedToReshareRecords {
      message += "\n\nYour travel party may need to be shared again, and the people you share with may need to reinstall Galavant and accept the new invite."
    }
    return message
  }

  private var backupExportErrorPresented: Binding<Bool> {
    Binding(
      get: { backupExport.errorMessage != nil },
      set: { if !$0 { backupExport.dismissError() } }
    )
  }

  private var backupRestoreErrorPresented: Binding<Bool> {
    Binding(
      get: { backupRestore.errorMessage != nil },
      set: { if !$0 { backupRestore.dismissError() } }
    )
  }

  private func refreshBackupOwnership() async {
    do {
      backupOwnership = try await DatabaseBackup.containsForeignOwnedRows(in: database)
    } catch {
      backupOwnershipCheckFailed = true
    }
  }

  private func backupExportCompleted(_ result: Result<URL, any Error>) {
    if case let .failure(error) = result { backupExport.recordExportFailure(error) }
    clearPreparedBackup()
  }

  private func clearPreparedBackup() {
    if let backupExportDocument { backupExport.discard(backupExportDocument.snapshot) }
    backupExportDocument = nil
  }

  private func backupRestoreSelected(_ result: Result<URL, any Error>) {
    switch result {
    case let .success(url):
      Task {
        await backupRestore.prepareRestore(from: url)
        isConfirmingRestore = backupRestore.isPrepared
      }
    case let .failure(error): backupRestore.recordImportFailure(error)
    }
  }
}

private final class GalavantBackupExportDocument: WritableDocument {
  typealias Writer = GalavantBackupExportDocumentWriter
  static let writableContentTypes: [UTType] = [.galavantSQLiteBackup]

  let snapshot: DatabaseBackup.Snapshot
  init(snapshot: DatabaseBackup.Snapshot) { self.snapshot = snapshot }

  func writer(configuration: sending DocumentWriteConfiguration) -> sending GalavantBackupExportDocumentWriter {
    GalavantBackupExportDocumentWriter()
  }

  func snapshot(contentType: UTType) async throws -> sending URL { snapshot.fileURL }
}

private struct GalavantBackupExportDocumentWriter: DocumentWriter {
  typealias Snapshot = URL
  func write(
    snapshot: sending URL,
    to destination: sending URL,
    previous: sending URL?,
    progress: consuming Subprogress
  ) async throws {
    try FileManager.default.copyItem(at: snapshot, to: destination)
  }
}

private extension UTType {
  static let galavantSQLiteBackup = UTType(
    exportedAs: "com.jonphillips.galavant.database-backup",
    conformingTo: .data
  )
}
