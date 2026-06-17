import Dependencies
import GalavantPlaces
import GalavantSchema
import SwiftUI
import UIKit

/// Hosts the SwiftUI capture-confirm sheet. Bootstraps the shared app-group
/// database **local-only** (no SyncEngine in an extension — the main app owns
/// sync and will push the new idea up on its next run), extracts the shared page,
/// and hands a `CaptureModel` to the confirm view.
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    try? prepareDependencies { try $0.bootstrapDatabase(startSyncEngine: false) }
    Task { await presentConfirm() }
  }

  @MainActor
  private func presentConfirm() async {
    let input = await CaptureExtraction.input(from: extensionContext)
    let model = CaptureModel(html: input.html, sourceURL: input.url)
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
