import Foundation

/// The pages pob shows in place of a page it couldn't show. They carry no scripts, and every value is escaped.
enum ErrorPage {
    /// The blocked page's one link. `Tab` acts on it only while that page is showing.
    static let loadAnywayAddress = "pob:load-anyway"

    static func html(for url: URL, error: Error) -> String {
        page(
            title: "Can't open \(shown(url))",
            detail: escape((error as NSError).localizedDescription),
            link: retryLink(url)
        )
    }

    static func crashHTML(for url: URL?) -> String {
        page(title: "This page stopped responding", detail: "Its process crashed twice in a row.", link: retryLink(url), label: "Reload")
    }

    /// No Retry, because the rules would only block it again.
    static func blockedHTML(for url: URL) -> String {
        page(title: "pob blocked \(shown(url))", detail: "It's on the ad blocker's lists.", link: loadAnywayAddress, label: "Load anyway")
    }

    /// Cancelled loads are the user's own doing, and WebKit's "frame load interrupted" is how a download starts.
    static func shouldShow(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return error.code != NSURLErrorCancelled && error.code != NSURLErrorUnsupportedURL }
        if error.domain == "WebKitErrorDomain" { return error.code != 102 && error.code != 204 }
        return true
    }

    /// For text and attribute values alike.
    static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;").replacing("'", with: "&#39;")
    }

    private static func shown(_ url: URL) -> String {
        escape(url.host() ?? url.absoluteString)
    }

    private static func retryLink(_ url: URL?) -> String? {
        guard let url, ["http", "https", "file"].contains(url.scheme) else { return nil }
        return url.absoluteString
    }

    private static func page(title: String, detail: String, link: String?, label: String = "Retry") -> String {
        let link = link.map { "<p><a href=\"\(escape($0))\">\(label)</a></p>" } ?? ""
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(title)</title>
        <style>body{font:15px -apple-system,sans-serif;max-width:32em;margin:20vh auto;padding:0 1em}\
        h1{font-size:1.3em}p{color:gray}a{color:inherit}</style>
        <h1>\(title)</h1><p>\(detail)</p>\(link)
        """
    }
}
