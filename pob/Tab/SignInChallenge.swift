import Foundation

enum ChallengeAction: Equatable { case trust, askForPassword, askAboutCertificate, useDefault }

enum SignInChallenge {
    static func action(method: String, hostIsAllowed: Bool, trustIsValid: Bool) -> ChallengeAction {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            .askForPassword
        case NSURLAuthenticationMethodServerTrust:
            trustIsValid ? .useDefault : (hostIsAllowed ? .trust : .askAboutCertificate)
        default:
            .useDefault
        }
    }
}

/// Counts a crash as a repeat when it comes soon after the reload that answered the last one.
struct CrashRecovery {
    static let window: TimeInterval = 10
    private var lastReload: Date?

    mutating func shouldReload(at now: Date) -> Bool {
        if let lastReload, now.timeIntervalSince(lastReload) < Self.window { return false }
        lastReload = now
        return true
    }
}
