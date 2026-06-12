import XCTest

final class PoolMapUITests: XCTestCase {
  @MainActor
  func testToggleToMapShowsMapView() {
    let app = XCUIApplication()
    app.launch()

    // Handle first-run name capture if it appears (state persists across runs).
    let nameField = app.textFields["Your name"]
    if nameField.waitForExistence(timeout: 3) {
      nameField.tap()
      nameField.typeText("Jon")
      app.buttons["Continue"].tap()
    }

    XCTAssert(app.buttons["Add Idea"].waitForExistence(timeout: 5))

    // Flip the list/map segmented control to map.
    app.segmentedControls.buttons.element(boundBy: 1).tap()

    // With no pinned ideas, the map shows its empty state — proves the map
    // view renders and the toggle works without depending on live search.
    XCTAssert(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "No pinned ideas"))
        .firstMatch
        .waitForExistence(timeout: 5)
    )
  }
}
