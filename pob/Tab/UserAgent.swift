import Foundation

enum UserAgent {
    static let fallback = "Version/27.0 Safari/605.1.15"

    /// Reads the installed Safari's version so sites keep treating pob as a current Safari.
    static func applicationName(
        safariInfoPlist: URL = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
    ) -> String {
        guard let info = NSDictionary(contentsOf: safariInfoPlist),
              let version = info["CFBundleShortVersionString"] as? String
        else { return fallback }
        return "Version/\(version) Safari/605.1.15"
    }
}
