import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct PermissionsTests {
    func settings() -> SiteSettings {
        SiteSettings(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")))
    }

    @Test func nothingIsRememberedAtFirst() {
        #expect(Permissions.remembered([.camera], host: "a.com", in: settings()) == nil)
    }
    @Test func answersAreRememberedPerSite() {
        let store = settings()
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        #expect(Permissions.remembered([.camera], host: "a.com", in: store) == true)
        #expect(Permissions.remembered([.camera], host: "b.com", in: store) == nil)
    }
    @Test func aCallNeedsBothAnswers() {
        let store = settings()
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        #expect(Permissions.remembered(Permissions.kinds(for: .cameraAndMicrophone), host: "a.com", in: store) == nil)
    }
    @Test func aDenialWins() {
        let store = settings()
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        Permissions.remember(false, kinds: [.microphone], host: "a.com", in: store)
        #expect(Permissions.remembered([.camera, .microphone], host: "a.com", in: store) == false)
    }
    @Test func settingsLinksPointAtTheRightPane() {
        #expect(Permissions.settingsURL(for: .camera).absoluteString.hasSuffix("Privacy_Camera"))
        #expect(Permissions.settingsURL(for: .microphone).absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(Permissions.settingsURL(for: .location).absoluteString.hasSuffix("Privacy_LocationServices"))
    }
    @Test func resettingASiteForgetsItsAnswersButKeepsZoom() {
        let store = settings()
        Permissions.remember(false, kinds: [.camera, .microphone], host: "a.com", in: store)
        Permissions.remember(true, kinds: [.location], host: "a.com", in: store)
        store["a.com"].allowsInvalidCertificate = true
        store["a.com"].zoom = 1.25
        Permissions.forget(host: "a.com", in: store)
        #expect(Permissions.remembered([.camera], host: "a.com", in: store) == nil)
        #expect(Permissions.remembered([.location], host: "a.com", in: store) == nil)
        #expect(store["a.com"].allowsInvalidCertificate == nil)
        #expect(store["a.com"].zoom == 1.25)
    }
    @Test func resettingASiteKeepsItsAdBlockerSwitch() {
        let store = settings()
        store["a.com"].adBlockerOff = true
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        Permissions.forget(host: "a.com", in: store)
        #expect(store["a.com"].adBlockerOff == true)
    }
    @Test func screenRecordingHasARouteToSettings() {
        #expect(Permissions.screenRecordingSettingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(CommandList.standard { _ in }.command(.screenRecordingSettings)?.title == "Screen Recording Settings")
        #expect(CommandList.standard { _ in }.command(.resetSitePermissions)?.title == "Reset Permissions for This Site")
    }
    @Test func theNewCommandsHaveNoShortcut() {
        let list = CommandList.standard { _ in }
        #expect(list.command(.screenRecordingSettings)?.key == "")
        #expect(list.command(.resetSitePermissions)?.key == "")
    }
    @Test func locationHasItsOwnPrompt() {
        #expect(Permissions.promptText(host: "a.com", kinds: [.location]) == "Allow a.com to use your location?")
        #expect(Permissions.promptText(host: "a.com", kinds: [.camera, .microphone]) == "Allow a.com to use your camera and microphone?")
    }
    @Test func kindsFollowTheCaptureType() {
        #expect(Permissions.kinds(for: .camera) == [.camera])
        #expect(Permissions.kinds(for: .microphone) == [.microphone])
        #expect(Permissions.kinds(for: .cameraAndMicrophone) == [.camera, .microphone])
    }

    // MARK: The decision flow, with the alert and macOS answered by the test

    /// What a run of `resolve` did.
    final class Run {
        var decision: WKPermissionDecision?
        var alerts: [String] = []
        var opened: [URL] = []
    }

    func resolve(
        _ store: SiteSettings, kinds: [PermissionKind] = [.camera], host: String = "a.com",
        macOSAllows: Bool = true, response: NSApplication.ModalResponse
    ) -> Run {
        let run = Run()
        Permissions.resolve(
            kinds: kinds, host: host, text: Permissions.promptText(host: host, kinds: kinds), settings: store,
            macOSAllows: { _ in macOSAllows },
            present: { alert, completion in run.alerts.append(alert.messageText); completion(response) },
            openSettings: { run.opened.append($0) },
            decision: { run.decision = $0 })
        return run
    }

    @Test func aRealAnswerIsRemembered() {
        let store = settings()
        let first = resolve(store, response: .alertFirstButtonReturn)
        #expect(first.decision == .grant)
        #expect(first.alerts == ["Allow a.com to use your camera?"])
        let again = resolve(store, response: .cancel)
        #expect(again.decision == .grant)
        #expect(again.alerts.isEmpty)
    }
    @Test func aRememberedDenialAsksNothing() {
        let store = settings()
        _ = resolve(store, response: .alertSecondButtonReturn)
        let again = resolve(store, response: .alertFirstButtonReturn)
        #expect(again.decision == .deny)
        #expect(again.alerts.isEmpty)
    }
    @Test func aCancelDeniesOnceAndRemembersNothing() {
        let store = settings()
        #expect(resolve(store, response: .cancel).decision == .deny)
        #expect(Permissions.remembered([.camera], host: "a.com", in: store) == nil)
    }
    @Test func macOSDenialExplainsAndStoresNothing() {
        let store = settings()
        let run = resolve(store, macOSAllows: false, response: .alertFirstButtonReturn)
        #expect(run.decision == .deny)
        #expect(run.alerts.count == 1)
        #expect(run.alerts.first != "Allow a.com to use your camera?")
        #expect(run.opened == [Permissions.settingsURL(for: .camera)])
        #expect(Permissions.remembered([.camera], host: "a.com", in: store) == nil)
    }
    @Test func macOSDenialWithoutTheButtonOpensNothing() {
        let run = resolve(settings(), macOSAllows: false, response: .cancel)
        #expect(run.decision == .deny)
        #expect(run.opened.isEmpty)
    }
    @Test func macOSDenialBeatsARememberedAllow() {
        let store = settings()
        Permissions.remember(true, kinds: [.microphone], host: "a.com", in: store)
        let run = resolve(store, kinds: [.microphone], macOSAllows: false, response: .alertSecondButtonReturn)
        #expect(run.decision == .deny)
        #expect(run.opened.isEmpty)
        #expect(Permissions.remembered([.microphone], host: "a.com", in: store) == true)
    }

    // MARK: Through the tab

    @Test func theTabKeysAnswersByThePageHostNotTheFrameOrigin() async {
        let tab = await tabWith(html: "<p>x</p>") // https://localhost/
        tab.alertSeam = { _ in .alertFirstButtonReturn }
        tab.deviceAccess = { _ in true }
        var decision: WKPermissionDecision?
        tab.decide(kinds: [.camera], originHost: "b.com") { decision = $0 }
        #expect(decision == .grant)
        #expect(Permissions.remembered([.camera], host: "localhost", in: tab.profile.siteSettings) == true)
        #expect(Permissions.remembered([.camera], host: "b.com", in: tab.profile.siteSettings) == nil)
    }
    @Test func aPageWithNoWindowDeniesWithoutRememberingOrPrompting() async {
        let tab = await tabWith(html: "<p>x</p>")
        tab.deviceAccess = { _ in true }
        var decision: WKPermissionDecision?
        let modal = await wentModal { tab.decide(kinds: [.location], originHost: "localhost") { decision = $0 } }
        #expect(!modal)
        #expect(decision == .deny)
        #expect(Permissions.remembered([.location], host: "localhost", in: tab.profile.siteSettings) == nil)
    }
}
