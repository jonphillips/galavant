import Dependencies
import GalavantCaptureUI
import GalavantPlaces
import GalavantSchema
import SwiftUI
import UIKit

/// Hosts the SwiftUI capture-confirm sheet. Bootstraps the shared app-group database
/// with a **stopped** SyncEngine ("construct, don't run"): constructing it installs
/// SQLiteData's sync triggers so the captured idea gets `SyncMetadata` + a pending
/// record-zone change the main app later drains — without it the capture never leaves
/// the device. The extension never `start()`s or networks; it only waits for its
/// pending change to persist before completing (see `CaptureModel.save`).
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    try? prepareDependencies { try $0.bootstrapDatabaseForShareExtension() }
    Task { await presentConfirm() }
  }

  @MainActor
  private func presentConfirm() async {
    let input = await CaptureExtraction.input(from: extensionContext)
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
