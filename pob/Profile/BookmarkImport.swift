import Foundation

/// Reads the Netscape bookmark files Safari and Chrome export. The file is untrusted, so every quantifier is bounded.
enum BookmarkImport {
    struct Item: Equatable {
        var title: String
        var url: URL
        var folder: String?       // nested folder names joined with " / "
    }

    static func parse(_ html: String) -> [Item] {
        let token = #/<h3\b[^>]{0,20000}>(.{0,2000}?)</h3\s*>|(<dl\b[^>]{0,20000}>)|(</dl\s*>)|<a\b([^>]{0,20000})>(.{0,2000}?)</a\s*>/#
            .ignoresCase().dotMatchesNewlines()
        let href = #/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/#.ignoresCase()
        let tag = #/<[^>]*>/#
        var stack: [String?] = []
        var pending: String?
        var items: [Item] = []
        for match in html.matches(of: token) {
            if let name = match.1 {
                pending = decode(String(name)).collapsingWhitespace
            } else if match.2 != nil {
                stack.append(pending)
                pending = nil
            } else if match.3 != nil {
                _ = stack.popLast()
            } else if let attributes = match.4, let inner = match.5 {
                guard let found = String(attributes).firstMatch(of: href),
                      let raw = found.1 ?? found.2 ?? found.3,
                      let url = URL(string: decode(String(raw))),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                      let host = url.host() else { continue }
                let title = decode(String(inner).replacing(tag, with: "")).collapsingWhitespace
                let folder = stack.compactMap { $0 }.joined(separator: " / ")
                items.append(Item(title: title.isEmpty ? host : title, url: url, folder: folder.isEmpty ? nil : folder))
            }
        }
        return items
    }

    /// `&amp;` goes last so `&amp;lt;` reads as the text `&lt;`.
    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let numeric = text.replacing(#/&#(x[0-9a-f]{1,6}|[0-9]{1,7});/#.ignoresCase()) { match in
            let digits = match.1.lowercased()
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
        }
        return numeric.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}

private extension String {
    var collapsingWhitespace: String { split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
