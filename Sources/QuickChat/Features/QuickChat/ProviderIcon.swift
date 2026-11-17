import AppKit
import CryptoKit

/// Uses bundled or locally cached artwork. Drawing an icon never makes a network request.
@MainActor
enum ProviderIcon {
    private static var images: [String: NSImage] = [:]
    private static func cacheFile(for url: URL) -> URL {
        let key = WebsiteFavicon.pageURL(for: url)?.absoluteString ?? url.absoluteString
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appendingPathComponent("dev.quickchat.omni/Favicons", isDirectory: true)
            .appendingPathComponent(digest + ".png")
    }

    static func store(_ png: Data, for url: URL) {
        let file = cacheFile(for: url)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            let prefix = file.lastPathComponent + ":"
            images = images.filter { !$0.key.hasPrefix(prefix) }
        } catch {
            // Keep the previous icon if storing its replacement fails.
        }
    }

    static func image(for url: URL, size: CGFloat) -> NSImage {
        let host = url.host?.lowercased() ?? ""
        let official: [(String, String)] = [
            ("chatgpt.com", "chatgpt"), ("claude.ai", "claude"), ("deepseek.com", "deepseek"),
            ("kimi.com", "kimi"), ("gemini.google.com", "gemini"), ("perplexity.ai", "perplexity"),
            ("copilot.microsoft.com", "copilot"), ("grok.com", "grok")
        ]
        let key = official.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
        let file = key == nil ? cacheFile(for: url) : nil
        let cacheKey = "\(file?.lastPathComponent ?? host):\(size)"
        if let image = images[cacheKey] { return image }
        var image: NSImage?
        if let key {
            let resource = Bundle.main.resourceURL?.appendingPathComponent("Providers/\(key).png")
            let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Providers/\(key).png")
            image = resource.flatMap { NSImage(contentsOf: $0) } ?? NSImage(contentsOf: development)
        }
        if let file { image = NSImage(contentsOf: file) }
        let result: NSImage
        if let image, key != "chatgpt" {
            let bounds = NSRect(x: 0, y: 0, width: size, height: size)
            result = NSImage(size: bounds.size, flipped: false) { _ in
                NSBezierPath(roundedRect: bounds, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
                let scale = min(size / image.size.width, size / image.size.height)
                let width = image.size.width * scale
                let height = image.size.height * scale
                image.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
                return true
            }
        } else {
            result = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")!
        }
        if key == "chatgpt" { result.isTemplate = true }
        result.size = NSSize(width: size, height: size)
        images[cacheKey] = result
        return result
    }
}

/// One canonical HTTPS address per website; rejects embedded credentials and malformed hosts.
enum ProviderAddress {
    static func matchesWebsite(host: String?, baseHost: String?) -> Bool {
        guard var host = host?.lowercased(), var base = baseHost?.lowercased() else { return false }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if base.hasPrefix("www.") { base = String(base.dropFirst(4)) }
        if base == "copilot.microsoft.com", host == "copilot.com" { return true }
        return host == base || host.hasSuffix("." + base)
    }
    static func parse(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text.contains("://") ? text : "https://" + text),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }), parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.path.isEmpty { parts.path = "/" }
        if parts.port == 443 { parts.port = nil }
        return parts.url
    }
}
