import Foundation

/// Reads the Netscape bookmark files Safari and Chrome export. The file is untrusted, so the scan is one forward pass:
/// no position is read twice, and a tag whose `>` (or an `<a>` or `<h3>` whose closing tag) is missing ends the parse.
nonisolated enum BookmarkImport {
    struct Item: Equatable {
        var title: String
        var url: URL
        var folder: String?       // nested folder names joined with " / "
    }

    static func parse(_ html: String) -> [Item] {
        let b = Array(html.utf8)
        var stack: [String?] = []
        var pending: String?
        var items: [Item] = []
        var i = 0
        while let lt = b[i...].firstIndex(of: UInt8(ascii: "<")) {
            var nameEnd = lt + 1
            while nameEnd < b.count, b[nameEnd] == UInt8(ascii: "/") || isLetterOrDigit(b[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: b[(lt + 1)..<nameEnd], as: UTF8.self).lowercased()
            i = lt + 1
            guard ["h3", "dl", "/dl", "a"].contains(name),
                  nameEnd == b.count || isSpace(b[nameEnd]) || b[nameEnd] == UInt8(ascii: ">") || b[nameEnd] == UInt8(ascii: "/")
            else { continue }
            guard let gt = b[nameEnd...].firstIndex(of: UInt8(ascii: ">")) else { return items }
            i = gt + 1
            switch name {
            case "dl":
                stack.append(pending)
                pending = nil
            case "/dl":
                _ = stack.popLast()
            default:
                let closing = Array((name == "a" ? "</a" : "</h3").utf8)
                guard let end = find(closing, in: b, from: i) else { return items }
                let inner = String(decoding: strippingTags(b[i..<end]), as: UTF8.self)
                i = end + closing.count
                let text = decode(inner).collapsingWhitespace
                if name == "h3" {
                    pending = text
                } else if let url = webURL(href(in: b[nameEnd..<gt])), let host = url.host() {
                    let folder = stack.compactMap { $0 }.joined(separator: " / ")
                    items.append(Item(title: text.isEmpty ? host : text, url: url, folder: folder.isEmpty ? nil : folder))
                }
            }
        }
        return items
    }

    /// Drops each `<...>`; a `<` with no `>` after it drops everything from there on.
    private static func strippingTags(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = bytes.startIndex
        while i < bytes.endIndex {
            guard let lt = bytes[i...].firstIndex(of: UInt8(ascii: "<")) else { out += bytes[i...]; break }
            out += bytes[i..<lt]
            guard let gt = bytes[lt...].firstIndex(of: UInt8(ascii: ">")) else { break }
            i = gt + 1
        }
        return out
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
    private static func isLetterOrDigit(_ c: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c | 0x20) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
    }

    /// The first position at or after `from` where `prefix` appears, ignoring case.
    private static func find(_ prefix: [UInt8], in b: [UInt8], from: Int) -> Int? {
        var i = from
        while let lt = b[i...].firstIndex(of: UInt8(ascii: "<")) {
            if lt + prefix.count <= b.count, zip(b[lt..<(lt + prefix.count)], prefix).allSatisfy({ $0 | 0x20 == $1 | 0x20 }) { return lt }
            i = lt + 1
        }
        return nil
    }

    /// The value of the attribute named exactly `href`, so `data-href` doesn't count.
    private static func href(in attrs: ArraySlice<UInt8>) -> String? {
        var i = attrs.startIndex
        let end = attrs.endIndex
        while i < end {
            while i < end, isSpace(attrs[i]) || attrs[i] == UInt8(ascii: "/") { i += 1 }
            let nameStart = i
            while i < end, !isSpace(attrs[i]), attrs[i] != UInt8(ascii: "="), attrs[i] != UInt8(ascii: "/") { i += 1 }
            let name = String(decoding: attrs[nameStart..<i], as: UTF8.self).lowercased()
            while i < end, isSpace(attrs[i]) { i += 1 }
            guard i < end, attrs[i] == UInt8(ascii: "=") else { continue }
            i += 1
            while i < end, isSpace(attrs[i]) { i += 1 }
            let valueStart: Int, valueEnd: Int
            if i < end, attrs[i] == UInt8(ascii: "\"") || attrs[i] == UInt8(ascii: "'") {
                let quote = attrs[i]
                valueStart = i + 1
                valueEnd = attrs[valueStart...].firstIndex(of: quote) ?? end
                i = min(valueEnd + 1, end)
            } else {
                valueStart = i
                while i < end, !isSpace(attrs[i]) { i += 1 }
                valueEnd = i
            }
            if name == "href" { return String(decoding: attrs[valueStart..<valueEnd], as: UTF8.self) }
        }
        return nil
    }

    private static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: decode(raw)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
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
    nonisolated var collapsingWhitespace: String { split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
