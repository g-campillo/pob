import Foundation

/// The pages pob shows in place of a page it couldn't show. They carry no scripts, and every value is escaped.
enum ErrorPage {
    static func html(for url: URL, error: Error) -> String {
        let shown = escape(url.host() ?? url.absoluteString)
        return page(
            title: "Can't open \(shown)",
            detail: escape((error as NSError).localizedDescription),
            retry: url
        )
    }

    static func crashHTML(for url: URL?) -> String {
        page(title: "This page stopped responding", detail: "Its process crashed twice in a row.", retry: url, label: "Reload")
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

    private static func page(title: String, detail: String, retry: URL?, label: String = "Retry") -> String {
        var link = ""
        if let retry, ["http", "https", "file"].contains(retry.scheme) {
            link = "<p><a href=\"\(escape(retry.absoluteString))\">\(label)</a></p>"
        }
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(title)</title>
        <style>body{font:15px -apple-system,sans-serif;max-width:32em;margin:20vh auto;padding:0 1em}\
        h1{font-size:1.3em}p{color:gray}a{color:inherit}</style>
        <h1>\(title)</h1><p>\(detail)</p>\(link)
        """
    }
}
