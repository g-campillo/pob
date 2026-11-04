import AppKit
import OSLog
import WebKit

/// Page icons cached as small PNGs, one per host. Icon addresses come from the page, so they are untrusted.
final class FaviconStore {
    static let maxBytes = 1_000_000
    static let maxPixels: CGFloat = 64

    private let directory: URL
    private var cache: [String: NSImage] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func image(forHost host: String) -> NSImage? {
        if let cached = cache[host] { return cached }
        guard let image = NSImage(contentsOf: Self.fileURL(in: directory, host: host)) else { return nil }
        cache[host] = image
        return image
    }

    /// Never leaves a failure behind but the letter tile.
    func update(host: String, from page: WKWebView) async {
        let declared = try? await page.evaluateJavaScript(#"document.querySelector('link[rel~="icon"]')?.href"#) as? String
        guard let icon = Self.iconURL(declared: declared, page: page.url),
              let data = await Self.fetch(icon),
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

    /// Ephemeral, so icon requests keep no cookies. Stops reading once the cap is passed.
    private static func fetch(_ url: URL) async -> Data? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
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
