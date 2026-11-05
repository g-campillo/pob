import Foundation

enum AddressInput: Equatable {
    case url(URL)
    case search(URL)

    private static let passthroughPrefixes = ["http://", "https://", "file://", "about:"]

    /// Query text keeps only characters that can't change how the URL parses.
    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+:;?#/,@$"))

    static func classify(_ text: String) -> AddressInput? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        guard input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return search(input) }

        let lowercased = input.lowercased()
        if passthroughPrefixes.contains(where: lowercased.hasPrefix), let url = URL(string: input) {
            return .url(url)
        }
        if let scheme = impliedScheme(for: input), let url = URL(string: "\(scheme)://\(input)") {
            return .url(url)
        }
        return search(input)
    }

    private static func search(_ text: String) -> AddressInput {
        let query = text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
        return .search(URL(string: "https://www.google.com/search?q=\(query)")!)
    }

    /// The scheme a bare host should get, or nil when the text isn't a host.
    private static func impliedScheme(for text: String) -> String? {
        let authority = String(text.prefix { !"/?#".contains($0) })

        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]"),
                  authority[..<close].contains(":"),
                  isPortSuffix(authority[authority.index(after: close)...])
            else { return nil }
            return "http"
        }

        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first?.lowercased(), !host.isEmpty else { return nil }
        if parts.count == 2, !isPort(parts[1]) { return nil }

        if host == "localhost" || host.hasSuffix(".local") || isIPv4(host) { return "http" }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let last = labels.last, last.allSatisfy(\.isLetter)
        else { return nil }
        return "https"
    }

    private static func isPortSuffix(_ text: Substring) -> Bool {
        text.isEmpty || (text.first == ":" && isPort(text.dropFirst()))
    }

    private static func isPort(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isNumber)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

/// What the system hands over when pob is the default browser.
enum IncomingLink {
    static func address(for url: URL) -> AddressInput? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return .url(url)
    }
}
