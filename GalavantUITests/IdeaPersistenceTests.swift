import XCTest

final class IdeaPersistenceTests: XCTestCase {
  @MainActor
  func testAddIdeaPersistsAcrossRelaunch() {
    let app = XCUIApplication()
    app.launch()

    let name = "Idea \(Int.random(in: 1000...9999))"
    app.buttons["Add Idea"].tap()
    let nameField = app.textFields["Name"]
    XCTAssert(nameField.waitForExistence(timeout: 5))
    nameField.tap()
    nameField.typeText(name)
    app.buttons["Save"].tap()
    XCTAssert(element(labeled: name, in: app).waitForExistence(timeout: 5))

    app.terminate()
    app.launch()
    XCTAssert(element(labeled: name, in: app).waitForExistence(timeout: 5))
  }

  private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", label))
      .firstMatch
  }
}
