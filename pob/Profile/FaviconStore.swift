import AppKit
import OSLog
import WebKit

/// Page icons cached as small PNGs, one per host. Icon addresses come from the page, so they are untrusted.
final class FaviconStore {
    static let maxBytes = 1_000_000
    static let maxPixels: CGFloat = 64
    /// The start of a page is enough. Its `<link>` tags are in its head.
    static let pageBytes = 256_000

    private let directory: URL
    private var cache: [String: NSImage] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func image(forHost host: String) -> NSImage? {
        if let cached = cache[host] { return cached }
        guard let file = NSImage(contentsOf: Self.fileURL(in: directory, host: host)) else { return nil }
        // Sites' icons are square, and nothing else pob draws is. The corners match the letter tile's.
        let image = NSImage(size: file.size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22).addClip()
            file.draw(in: rect)
            return true
        }
        cache[host] = image
        return image
    }

    /// Never leaves a failure behind but the letter tile.
    func update(host: String, from page: WKWebView) async {
        let declared = try? await page.evaluateJavaScript(#"document.querySelector('link[rel~="icon"]')?.href"#) as? String
        await save(Self.iconURL(declared: declared, page: page.url), host: host, configuration: .ephemeral)
    }

    /// For a saved bookmark, which has no page open: reads the icon link at the start of its page, or falls back to
    /// `/favicon.ico`. Only web pages are requested. A test passes a configuration that never reaches the network.
    func update(host: String, page: URL, configuration: URLSessionConfiguration = .ephemeral) async {
        guard let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let fetched = await Self.fetchPage(page, configuration: configuration)
        let declared = fetched.flatMap { Self.declaredIcon(in: $0.html) }
        await save(Self.iconURL(declared: declared, page: fetched?.url ?? page), host: host, configuration: configuration)
    }

    private func save(_ icon: URL?, host: String, configuration: URLSessionConfiguration) async {
        guard let icon,
              let data = await Self.fetch(icon, configuration: configuration),
              let png = Self.scaledPNG(from: data)
        else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: Self.fileURL(in: directory, host: host), options: .atomic)
            cache[host] = nil
        } catch {
            Logger(subsystem: "pob", category: "FaviconStore").error("Saving favicon failed: \(error)")
        }
    }

    /// Only web and data addresses are ever fetched. A page can declare a `file:` icon, and that must not be read.
    static func iconURL(declared: String?, page: URL?) -> URL? {
        func allowed(_ url: URL?) -> URL? {
            guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "data"].contains(scheme) else { return nil }
            return url
        }
        return allowed(declared.flatMap { URL(string: $0, relativeTo: page)?.absoluteURL })
            ?? allowed(URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL)
    }

    /// Letters, digits, dots and dashes pass. Anything else, a slash included, becomes an underscore.
    static func fileName(forHost host: String) -> String {
        let safe = host.lowercased().unicodeScalars.map { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-") ? Character(scalar) : "_"
        }
        return String(safe) + ".png"
    }

    static func letter(for host: String) -> String {
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    static func letterTile(for host: String, size: CGFloat) -> NSImage {
        let letter = letter(for: host)
        let hue = CGFloat(host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let color = NSColor(hue: hue, saturation: 0.5, brightness: 0.65, alpha: 1)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.55, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let box = text.size()
            text.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
            return true
        }
    }

    private static func fileURL(in directory: URL, host: String) -> URL {
        directory.appending(path: fileName(forHost: host), directoryHint: .notDirectory)
    }

    /// The `href` of the first `<link>` whose `rel` has the word `icon`. The page is untrusted, so this is one forward
    /// pass, like `BookmarkImport.parse`, and a `<link` with no `>` after it ends the scan.
    static func declaredIcon(in html: Data) -> String? {
        let b = Array(html)
        var i = 0
        while let lt = b[i...].firstIndex(of: UInt8(ascii: "<")) {
            i = lt + 1
            let nameEnd = lt + 5
            guard nameEnd < b.count,
                  zip(b[(lt + 1)..<nameEnd], "link".utf8).allSatisfy({ $0 | 0x20 == $1 }),
                  BookmarkImport.isSpace(b[nameEnd]) || b[nameEnd] == UInt8(ascii: "/")
            else { continue }
            guard let gt = b[nameEnd...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
            i = gt + 1
            let attrs = b[nameEnd..<gt]
            let rel = BookmarkImport.attribute("rel", in: attrs)?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
            if rel.contains("icon"), let href = BookmarkImport.attribute("href", in: attrs) {
                return BookmarkImport.decode(href).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// The start of the page, and the address it ended at. Anything but a 200 counts as no page, and the fallback is still tried.
    private static func fetchPage(_ url: URL, configuration: URLSessionConfiguration) async -> (html: Data, url: URL)? {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() } // the rest of a long page isn't wanted
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false // the icon request shares this configuration, so a cookie kept here would go out with it
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        var html = Data()
        do {
            for try await byte in bytes {
                html.append(byte)
                if html.count >= pageBytes { break }
            }
        } catch { return nil }
        return (html, response.url ?? url)
    }

    /// Sends no cookies, not even ones the page just set through the same configuration. Stops reading once the cap is passed.
    private static func fetch(_ url: URL, configuration: URLSessionConfiguration) async -> Data? {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard response.expectedContentLength <= maxBytes else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch { return nil }
        return data
    }

    private static func scaledPNG(from data: Data) -> Data? {
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(1, maxPixels / max(source.size.width, source.size.height))
        let width = max(1, Int((source.size.width * scale).rounded())), height = max(1, Int((source.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
