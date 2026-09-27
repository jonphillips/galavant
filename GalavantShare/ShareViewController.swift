import Dependencies
import GalavantCaptureUI
import GalavantPlaces
import GalavantSchema
import SwiftUI
import UIKit
import os

/// Hosts the SwiftUI capture-confirm sheet. Bootstraps the shared app-group database
/// with a **stopped** SyncEngine ("construct, don't run"): constructing it installs
/// SQLiteData's sync triggers so the captured idea gets `SyncMetadata` + a pending
/// record-zone change the main app later drains — without it the capture never leaves
/// the device. The extension never `start()`s or networks; it only waits for its
/// pending change to persist before completing (see `CaptureModel.save`).
final class ShareViewController: UIViewController {
  /// iOS may keep the extension process alive and build a fresh principal
  /// controller for the next share. Bootstrapping again would open a second
  /// database writer and a second SyncEngine over the same file (and trip swift-
  /// dependencies' "already accessed" check), so do it once per process.
  @MainActor private static var didBootstrap = false

  override func viewDidLoad() {
    super.viewDidLoad()
    if !Self.didBootstrap {
      Self.didBootstrap = true
      do {
        try prepareDependencies { try $0.bootstrapDatabaseForShareExtension() }
      } catch {
        CaptureModel.log.error("share: database bootstrap failed: \(error)")
      }
    }
    Task { await presentConfirm() }
  }

  @MainActor
  private func presentConfirm() async {
    let input = await CaptureExtraction.input(from: extensionContext)
    CaptureModel.log.info(
      "share: input location=\(input.location != nil) html=\(input.html.count) url=\(input.url != nil)")
    let model =
      input.location.map(CaptureModel.init(location:))
      ?? CaptureModel(html: input.html, sourceURL: input.url)
    let root = CaptureConfirmView(model: model) { [weak self] in self?.finish() }

    let host = UIHostingController(rootView: root)
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    host.didMove(toParent: self)
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
