import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches public icon artwork using a separate connection with no WebKit session state.
enum WebsiteFavicon {
    static func pageURL(for website: URL) -> URL? {
        var page = URLComponents(url: website, resolvingAgainstBaseURL: false)
        page?.query = nil
        page?.fragment = nil
        return page?.url
    }

    static func fetch(for website: URL, configuration: URLSessionConfiguration = .ephemeral) async -> Data? {
        guard let page = pageURL(for: website) else { return nil }
        let boundary = IconOrigin(page)
        guard boundary.allows(page) else { return nil }

        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: boundary, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var candidates: [URL] = []
        if let (data, response) = try? await read(page, using: session, limit: 524_288, allowPrefix: true),
           let finalURL = response.url, boundary.allows(finalURL) {
            candidates = declaredIcons(in: String(decoding: data, as: UTF8.self), page: finalURL)
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
            candidates.append(fallback)
        }
        var seen = Set<URL>()
        for candidate in candidates where boundary.allows(candidate) && seen.insert(candidate).inserted {
            guard !Task.isCancelled else { return nil }
            if let (data, _) = try? await read(candidate, using: session, limit: 524_288),
               let png = rasterPNG(data) { return png }
        }
        return nil
    }

    static func declaredIcons(in html: String, page: URL) -> [URL] {
        let header = html.range(of: "</head", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        let tags = try! NSRegularExpression(pattern: #"(?i)<link\s+[^>]*>"#)
        let attributes = try! NSRegularExpression(pattern: #"(?i)\s(rel|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        return tags.matches(in: header, range: NSRange(header.startIndex..., in: header)).lazy.compactMap { match -> URL? in
            guard let range = Range(match.range, in: header) else { return nil }
            let tag = String(header[range])
            var values: [String: String] = [:]
            for attr in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let key = Range(attr.range(at: 1), in: tag),
                      let value = (2...4).compactMap({ Range(attr.range(at: $0), in: tag) }).first else { continue }
                values[String(tag[key]).lowercased()] = String(tag[value])
            }
            let rel = values["rel"]?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
            guard rel.contains("icon") || rel.contains("apple-touch-icon"),
                  let href = values["href"], !href.isEmpty else { return nil }
            return URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL
        }.prefix(6).map { $0 }
    }

    private static func read(_ url: URL, using session: URLSession, limit: Int, allowPrefix: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (allowPrefix || http.expectedContentLength <= Int64(limit)) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            if data.count == limit {
                if allowPrefix { break }
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, http)
    }

    static func rasterPNG(_ data: Data) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source),
              ["public.png", "public.jpeg", "com.compuserve.gif", "com.microsoft.ico", "org.webmproject.webp"].contains(type as String),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }
}

private final class IconOrigin: NSObject, URLSessionTaskDelegate {
    private let host: String?
    private let port: Int

    init(_ url: URL) {
        host = Self.normalizedHost(url.host)
        port = url.port ?? 443
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func allows(_ url: URL) -> Bool {
        url.scheme == "https" && host != nil && Self.normalizedHost(url.host) == host &&
        (url.port ?? 443) == port && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let trust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(trust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
