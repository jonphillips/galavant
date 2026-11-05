import Dependencies
@testable import GalavantSchema
import Testing

struct DatabaseSuspensionConfigurationTests {
  @Test func onlyTheLiveSharedStoreObservesSuspension() {
    #expect(DependencyValues.observesSuspension(context: .live, path: nil))
    #expect(!DependencyValues.observesSuspension(context: .live, path: "/restore.sqlite"))
    #expect(!DependencyValues.observesSuspension(context: .test, path: nil))
    #expect(!DependencyValues.observesSuspension(context: .preview, path: nil))
  }
}
