import XCTest

final class PoolFlowUITests: XCTestCase {
  @MainActor
  func testFirstRunThenCaptureIdea() {
    let app = XCUIApplication()
    app.launch()

    // First-run planner capture.
    let nameField = app.textFields["Your name"]
    XCTAssert(nameField.waitForExistence(timeout: 5), "name capture sheet should appear")
    nameField.tap()
    nameField.typeText("Jon")
    app.buttons["Continue"].tap()

    // Capture an idea.
    let addButton = app.buttons["Add Idea"]
    XCTAssert(addButton.waitForExistence(timeout: 5), "ideas list should appear after naming")
    addButton.tap()
    let ideaName = app.textFields["Name"]
    XCTAssert(ideaName.waitForExistence(timeout: 5))
    ideaName.tap()
    ideaName.typeText("Tivoli Gardens")
    app.buttons["Save"].tap()

    XCTAssert(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "Tivoli Gardens"))
        .firstMatch
        .waitForExistence(timeout: 5),
      "captured idea should appear in the list"
    )
  }
}
