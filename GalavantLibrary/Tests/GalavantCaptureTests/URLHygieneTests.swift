import Foundation
import Testing

@testable import GalavantCapture

@Suite struct URLHygieneTests {
  @Test("upgrades cleartext HTTP while preserving the path and query")
  func upgradesHTTP() {
    #expect(
      URLHygiene.httpsUpgraded(URL(string: "http://x.de")!)
        == URL(string: "https://x.de")!
    )
    #expect(
      URLHygiene.httpsUpgraded(URL(string: "http://x.de/path?q=1")!)
        == URL(string: "https://x.de/path?q=1")!
    )
  }

  @Test("leaves HTTPS, relative, and other-scheme URLs unchanged")
  func leavesNonHTTPURLsUnchanged() {
    let https = URL(string: "https://x.de")!
    let relative = URL(string: "/path?q=1")!
    let ftp = URL(string: "ftp://x.de/file")!

    #expect(URLHygiene.httpsUpgraded(https) == https)
    #expect(URLHygiene.httpsUpgraded(relative) == relative)
    #expect(URLHygiene.httpsUpgraded(ftp) == ftp)
  }
}
