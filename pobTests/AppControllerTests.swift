import Testing
@testable import pob

@Suite struct AppControllerTests {
    @Test func hostedTestsSkipWindowSetup() {
        #expect(AppController.isRunningTests)
    }
}
