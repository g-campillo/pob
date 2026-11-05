import AppKit
import Foundation
import Security
import Testing
import WebKit
@testable import pob

private nonisolated final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
    let trust: SecTrust
    init(_ trust: SecTrust, host: String) {
        self.trust = trust
        super.init(host: host, port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { nil }
    override var serverTrust: SecTrust? { trust }
}

private nonisolated final class Sender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// A self-signed certificate, so evaluation really fails. No network, no window.
private func badCertificate(host: String) -> URLAuthenticationChallenge {
    let der = Data(base64Encoded: "MIIDBDCCAeygAwIBAgIUX8dwb/RU36aWAJYF6d4HhGqI4ZgwDQYJKoZIhvcNAQELBQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MTEwNDIzMTYxNVoXDTI2MTIwNDIzMTYxNVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyguHnGToGY6D23FJVESSIF3/RdHMxn/L+D55+42/0v7fxfL4RW/M09oBDmthLas4XIeq8yMEaTXo+euqDCSQzS0Bux4KC6to543IPOZvwDl7jT6aTJSaSwm197+qEd9BH9NQTzbm7qh/5x2VN5GA/hmjLob4oNMge8RIuySpAKJgoKRpZrPXh1OCO/M8wE9cvDv+7voo8UpqrlvfQoSKXb1gXD8J/2ID1kpIpfWu3httQLn9ucE0RFeI7/C7LDY2D94vqbif+NFQzR7EMusO/DRnqapRdZXm2R66vISUPkL/F0G3vRpmVFJXbdz1iSWp95LqPMA03gPDHle/7PxG7wIDAQABo04wTDAdBgNVHQ4EFgQU7Jvz+GYA/hIreZKppq3I42N7bakwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBALsthiCrBWiyp0G5VOoGv7m5cjoCcMJ3qvlktopSIPOgfUX6dzQKBaaPPDYQjKLx+33vlgCk/fEeGypSaF6bU77FtDvOkvA94P8qqv9egQtWIf1CMIJY5nWpIdn/+i1DNuCzkM7VQ10FqLLJ5EDUWLRQn3hUxdBUwf0wxXO6NPYp8p0nlenjYDFfGdfeoMm5AyPppmndowPcpOc309B9hKAG7TmMfEiaM6ofaH3cGepGn1fID67gKoalhIGD4Lfoht+MdxN3Iybyx9B1xfRKsiCRhBTMyzHathtXv1Bhog2pCPdE44YNvfM0L5B0YdXmcpYLyiHX7atmw2x+uDNQn10=")!
    let certificate = SecCertificateCreateWithData(nil, der as CFData)!
    var trust: SecTrust?
    SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
    return URLAuthenticationChallenge(
        protectionSpace: TrustSpace(trust!, host: host), proposedCredential: nil, previousFailureCount: 0,
        failureResponse: nil, error: nil, sender: Sender())
}

private func passwordChallenge(host: String, realm: String?, failures: Int = 0) -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
        protectionSpace: URLProtectionSpace(host: host, port: 80, protocol: "http", realm: realm, authenticationMethod: NSURLAuthenticationMethodHTTPBasic),
        proposedCredential: nil, previousFailureCount: failures, failureResponse: nil, error: nil, sender: Sender())
}

private struct Answer {
    var disposition: URLSession.AuthChallengeDisposition
    var credential: URLCredential?
}

private func answer(_ tab: Tab, _ challenge: URLAuthenticationChallenge) async -> Answer {
    await withCheckedContinuation { continuation in
        tab.webView(tab.webView, didReceive: challenge) { disposition, credential in
            continuation.resume(returning: Answer(disposition: disposition, credential: credential))
        }
    }
}

private func fields(of alert: NSAlert) -> [NSTextField] { alert.accessoryView?.subviews.compactMap { $0 as? NSTextField } ?? [] }

@Suite struct TrustPathTests {
    @Test(.timeLimit(.minutes(1))) func anInvalidCertificateWithNoWindowIsRefusedAndNotRemembered() async {
        let tab = Tab(profile: .temporary())
        #expect(await answer(tab, badCertificate(host: "bad.example")).disposition == .cancelAuthenticationChallenge)
        #expect(tab.profile.siteSettings["bad.example"].allowsInvalidCertificate == nil)
    }
    @Test(.timeLimit(.minutes(1))) func anEvaluationThatCantStartStillAnswersTheChallengeOnce() async {
        let tab = Tab(profile: .temporary())
        tab.evaluateTrust = { _, _ in errSecParam }
        tab.profile.siteSettings["dev.example"].allowsInvalidCertificate = nil
        #expect(await answer(tab, badCertificate(host: "dev.example")).disposition == .cancelAuthenticationChallenge)
    }
    @Test(.timeLimit(.minutes(1))) func anAllowedHostIsTrusted() async {
        let tab = Tab(profile: .temporary())
        tab.profile.siteSettings["dev.example"].allowsInvalidCertificate = true
        #expect(await answer(tab, badCertificate(host: "dev.example")).disposition == .useCredential)
    }
    @Test(.timeLimit(.minutes(1))) func allowingOneHostLeavesOthersRefused() async {
        let tab = Tab(profile: .temporary())
        tab.profile.siteSettings["dev.example"].allowsInvalidCertificate = true
        #expect(await answer(tab, badCertificate(host: "other.example")).disposition == .cancelAuthenticationChallenge)
    }
    @Test(.timeLimit(.minutes(1))) func allowThisSiteRemembersTheHostAndTrustsIt() async {
        let tab = Tab(profile: .temporary())
        tab.alertSeam = { _ in .alertSecondButtonReturn }
        let result = await answer(tab, badCertificate(host: "dev.example"))
        #expect(result.disposition == .useCredential)
        #expect(tab.profile.siteSettings["dev.example"].allowsInvalidCertificate == true)
    }
    @Test(.timeLimit(.minutes(1))) func oneRefusalAsksOnceEvenWhenTheConnectionRetries() async {
        let tab = Tab(profile: .temporary())
        var asked = 0
        tab.alertSeam = { _ in asked += 1; return .alertFirstButtonReturn }
        let first = await answer(tab, badCertificate(host: "dev.example"))
        let second = await answer(tab, badCertificate(host: "dev.example"))
        #expect(first.disposition == .cancelAuthenticationChallenge && second.disposition == .cancelAuthenticationChallenge)
        #expect(asked == 1)
        #expect(tab.profile.siteSettings["dev.example"].allowsInvalidCertificate == nil)
    }
    @Test(.timeLimit(.minutes(1))) func aRefusalWithNoWindowIsRetriedWhenTheTabIsActivated() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let tab = tabs.newTab(nil, activate: false)
        let id = tabs.list.records[1].id
        let address = URL(string: "https://localhost:1/")!
        tab.mainFrameURL = address
        let result = await answer(tab, badCertificate(host: "localhost"))
        #expect(result.disposition == .cancelAuthenticationChallenge)
        #expect(tab.retryURL == address)
        #expect(tab.profile.siteSettings["localhost"].allowsInvalidCertificate == nil)
        tabs.activate(id)
        #expect(tab.retryURL == nil)
        #expect(tab.webView.isLoading)
    }
    @Test(.timeLimit(.minutes(1))) func aPasswordIsAskedForByHostAndKeptForTheSession() async throws {
        let tab = Tab(profile: .temporary())
        var shown: NSAlert?
        tab.alertSeam = { alert in
            shown = alert
            let boxes = fields(of: alert)
            boxes.first { !($0 is NSSecureTextField) }?.stringValue = "me"
            boxes.first { $0 is NSSecureTextField }?.stringValue = "secret"
            return .alertFirstButtonReturn
        }
        let result = await answer(tab, passwordChallenge(host: "files.example", realm: "Private"))
        #expect(shown?.messageText.contains("files.example") == true)
        #expect(shown?.informativeText.contains("\"Private\"") == true)
        #expect(result.disposition == .useCredential)
        #expect(result.credential?.user == "me" && result.credential?.password == "secret")
        #expect(result.credential?.persistence == .forSession)
    }
    @Test(.timeLimit(.minutes(1))) func cancellingThePasswordSheetCancelsTheChallenge() async {
        let tab = Tab(profile: .temporary())
        tab.alertSeam = { _ in .alertSecondButtonReturn }
        #expect(await answer(tab, passwordChallenge(host: "files.example", realm: nil)).disposition == .cancelAuthenticationChallenge)
    }
    @Test(.timeLimit(.minutes(1))) func aPasswordChallengeWithNoWindowCancels() async {
        let tab = Tab(profile: .temporary())
        #expect(await answer(tab, passwordChallenge(host: "files.example", realm: nil)).disposition == .cancelAuthenticationChallenge)
    }
    @Test(.timeLimit(.minutes(1))) func theRealmIsCutShort() async {
        let tab = Tab(profile: .temporary())
        var text = ""
        tab.alertSeam = { text = $0.informativeText; return .alertSecondButtonReturn }
        _ = await answer(tab, passwordChallenge(host: "h.example", realm: String(repeating: "x", count: 500)))
        #expect(text.count < 200)
    }
    @Test(.timeLimit(.minutes(1))) func aWrongPasswordIsAskedAgainWithAnExplanation() async {
        let tab = Tab(profile: .temporary())
        var text = ""
        tab.alertSeam = { text = $0.informativeText; return .alertSecondButtonReturn }
        _ = await answer(tab, passwordChallenge(host: "h.example", realm: nil, failures: 1))
        #expect(text.contains("Try again"))
    }
}
