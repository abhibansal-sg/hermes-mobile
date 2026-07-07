import Foundation

enum RichURLEmbedProvider: String, Equatable, Sendable {
    case googleMaps = "googlemaps"
    case instagram
    case openStreetMap = "openstreetmap"
    case pinterest
    case spotify
    case tiktok
    case twitter
    case vimeo
    case youtube
}

struct RichURLEmbedDescriptor: Equatable, Sendable {
    let provider: RichURLEmbedProvider
    let sourceURL: URL
    let embedURL: URL
    let label: String
    let maxWidth: Double
    let aspectRatio: Double?
    let fixedHeight: Double?
    let id: String
}

enum RichURLEmbedDetector {
    static func detect(_ rawURL: String) -> RichURLEmbedDescriptor? {
        guard let url = URL(string: rawURL) else { return nil }
        return detect(url)
    }

    static func detect(_ url: URL) -> RichURLEmbedDescriptor? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        return youtube(url)
            ?? vimeo(url)
            ?? instagram(url)
            ?? pinterest(url)
            ?? tiktok(url)
            ?? twitter(url)
            ?? spotify(url)
            ?? googleMaps(url)
            ?? openStreetMap(url)
    }

    // MARK: - YouTube

    private static func youtube(_ url: URL) -> RichURLEmbedDescriptor? {
        let host = bareHost(url.host() ?? "")
        let segments = pathSegments(url)
        let id: String

        if host == "youtu.be" {
            id = segments.first ?? ""
        } else if host == "youtube.com" || host == "youtube-nocookie.com" {
            if segments.first == "watch" {
                id = queryValue("v", in: url) ?? ""
            } else if let first = segments.first, ["embed", "shorts", "live", "v"].contains(first) {
                id = segments.dropFirst().first ?? ""
            } else {
                return nil
            }
        } else {
            return nil
        }

        guard id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            return nil
        }

        var params = [("modestbranding", "1"), ("rel", "0")]
        if let start = startSeconds(queryValue("t", in: url) ?? queryValue("start", in: url)) {
            params.append(("start", String(start)))
        }

        return descriptor(
            provider: .youtube,
            sourceURL: url,
            embedURL: "https://www.youtube-nocookie.com/embed/\(id)?\(formEncoded(params))",
            label: "YouTube",
            maxWidth: 640,
            aspectRatio: 16 / 9,
            fixedHeight: nil,
            id: "youtube:\(id)"
        )
    }

    private static func startSeconds(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        if let seconds = Int(value) {
            return seconds > 0 ? seconds : nil
        }

        let pattern = #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            match.range(at: 0).length > 0
        else {
            return nil
        }

        func part(_ index: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return 0 }
            return Int(value[swiftRange]) ?? 0
        }

        let seconds = part(1) * 3600 + part(2) * 60 + part(3)
        return seconds > 0 ? seconds : nil
    }

    // MARK: - Spotify

    private static func spotify(_ url: URL) -> RichURLEmbedDescriptor? {
        guard bareHost(url.host() ?? "") == "open.spotify.com" else { return nil }

        let segments = pathSegments(url)
        let start = segments.first?.hasPrefix("intl-") == true ? 1 : 0
        guard segments.count > start + 1 else { return nil }

        let type = segments[start]
        let id = segments[start + 1]
        let embedTypes: Set<String> = ["album", "artist", "episode", "playlist", "show", "track"]

        guard
            embedTypes.contains(type),
            id.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
        else {
            return nil
        }

        return descriptor(
            provider: .spotify,
            sourceURL: url,
            embedURL: "https://open.spotify.com/embed/\(type)/\(id)",
            label: "Spotify",
            maxWidth: 480,
            aspectRatio: nil,
            fixedHeight: 152,
            id: "spotify:\(type):\(id)"
        )
    }

    // MARK: - Vimeo

    private static func vimeo(_ url: URL) -> RichURLEmbedDescriptor? {
        let host = bareHost(url.host() ?? "")
        guard host == "vimeo.com" || host == "player.vimeo.com" else { return nil }

        // The clip id is the last all-digits segment, covering vimeo.com/123,
        // /channels/x/123, /groups/x/videos/123, and player/video/123.
        let id = pathSegments(url).reversed().first { segment in
            segment.range(of: #"^\d+$"#, options: .regularExpression) != nil
        }

        guard let id, !id.isEmpty else { return nil }

        return descriptor(
            provider: .vimeo,
            sourceURL: url,
            embedURL: "https://player.vimeo.com/video/\(id)",
            label: "Vimeo",
            maxWidth: 640,
            aspectRatio: 16 / 9,
            fixedHeight: nil,
            id: "vimeo:\(id)"
        )
    }

    // MARK: - Instagram

    private static func instagram(_ url: URL) -> RichURLEmbedDescriptor? {
        guard bareHost(url.host() ?? "") == "instagram.com" else { return nil }

        let segments = pathSegments(url)
        guard segments.count >= 2 else { return nil }

        let typeRaw = segments[0]
        let code = segments[1]
        // Desktop maps /reels/ to reel; p/reel/tv are the embeddable post types.
        let type = typeRaw == "reels" ? "reel" : typeRaw

        guard
            ["p", "reel", "tv"].contains(type),
            code.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        else {
            return nil
        }

        return descriptor(
            provider: .instagram,
            sourceURL: url,
            embedURL: "https://www.instagram.com/\(type)/\(code)/embed",
            label: "Instagram",
            maxWidth: 400,
            aspectRatio: nil,
            fixedHeight: 450,
            id: "instagram:\(code)"
        )
    }

    // MARK: - Pinterest

    private static func pinterest(_ url: URL) -> RichURLEmbedDescriptor? {
        // Pinterest runs many locale TLDs (pinterest.co.uk, fr.pinterest.com, ...).
        let host = bareHost(url.host() ?? "")
        guard isPinterestHost(host) else { return nil }

        let segments = pathSegments(url)
        guard
            segments.count >= 2,
            segments[0] == "pin",
            segments[1].range(of: #"^\d+$"#, options: .regularExpression) != nil
        else {
            return nil
        }

        let id = segments[1]

        return descriptor(
            provider: .pinterest,
            sourceURL: url,
            embedURL: "https://assets.pinterest.com/ext/embed.html?id=\(id)",
            label: "Pinterest",
            maxWidth: 236,
            aspectRatio: nil,
            fixedHeight: 380,
            id: "pinterest:\(id)"
        )
    }

    // MARK: - TikTok

    private static func tiktok(_ url: URL) -> RichURLEmbedDescriptor? {
        guard bareHost(url.host() ?? "") == "tiktok.com" else { return nil }

        let segments = pathSegments(url)
        guard
            let videoIndex = segments.firstIndex(of: "video"),
            videoIndex + 1 < segments.count
        else {
            return nil
        }

        let id = segments[videoIndex + 1]
        guard id.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }

        return descriptor(
            provider: .tiktok,
            sourceURL: url,
            embedURL: "https://www.tiktok.com/player/v1/\(id)",
            label: "TikTok",
            maxWidth: 365,
            aspectRatio: 9 / 16,
            fixedHeight: nil,
            id: "tiktok:\(id)"
        )
    }

    // MARK: - Twitter / X

    private static func twitter(_ url: URL) -> RichURLEmbedDescriptor? {
        let host = bareHost(url.host() ?? "")
        guard host == "twitter.com" || host == "x.com" else { return nil }

        let segments = pathSegments(url)
        guard
            let statusIndex = segments.firstIndex(of: "status"),
            statusIndex + 1 < segments.count
        else {
            return nil
        }

        let id = segments[statusIndex + 1]
        guard id.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }

        // Desktop renders Twitter via the widgets.js blockquote (renderer
        // 'tweet', no embed URL). iOS has no JS widget runtime, so it loads the
        // same iframe the widget injects as a top-level WKWebView document -
        // the closest available parity. The card's load-failed fallback covers
        // any transient render gap.
        return descriptor(
            provider: .twitter,
            sourceURL: url,
            embedURL: "https://platform.twitter.com/embed/Tweet.html?id=\(id)&dnt=true",
            label: "X",
            maxWidth: 480,
            aspectRatio: nil,
            fixedHeight: 400,
            id: "twitter:\(id)"
        )
    }

    // MARK: - Maps

    private static func googleMaps(_ url: URL) -> RichURLEmbedDescriptor? {
        let host = bareHost(url.host() ?? "")
        guard host == "google.com" || host == "maps.google.com" || host.hasPrefix("google.") else {
            return nil
        }

        let path = url.path
        let isMapsPath = host.hasPrefix("maps.") || path.hasPrefix("/maps")
        guard isMapsPath else { return nil }

        var query = ""
        var zoom = ""

        if let coords = firstMatch(
            #"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)(?:,(\d+(?:\.\d+)?)z)?"#,
            in: path
        ) {
            query = "\(coords[1]),\(coords[2])"
            if coords.indices.contains(3), let zoomValue = Double(coords[3]) {
                zoom = String(Int(zoomValue.rounded()))
            }
        } else if let value = queryValue("q", in: url) ?? queryValue("query", in: url) {
            query = value.replacingOccurrences(of: "+", with: " ")
        } else if let place = firstMatch(#"/place/([^/@]+)"#, in: path) {
            query = place[1]
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? place[1]
        }

        guard !query.isEmpty else { return nil }

        var params = [("output", "embed"), ("q", query)]
        if !zoom.isEmpty {
            params.append(("z", zoom))
        }

        return descriptor(
            provider: .googleMaps,
            sourceURL: url,
            embedURL: "https://maps.google.com/maps?\(formEncoded(params))",
            label: "Google Maps",
            maxWidth: 640,
            aspectRatio: 16 / 10,
            fixedHeight: nil,
            id: "googlemaps:\(query)\(!zoom.isEmpty ? "@\(zoom)" : "")"
        )
    }

    private static func openStreetMap(_ url: URL) -> RichURLEmbedDescriptor? {
        guard bareHost(url.host() ?? "") == "openstreetmap.org" else { return nil }
        guard
            let fragment = url.fragment,
            let match = firstMatch(#"map=(\d+(?:\.\d+)?)\/(-?\d+(?:\.\d+)?)\/(-?\d+(?:\.\d+)?)"#, in: fragment),
            let zoom = Double(match[1]),
            let latitude = Double(match[2]),
            let longitude = Double(match[3])
        else {
            return nil
        }

        let lonDelta = 360 / pow(2, zoom)
        let latDelta = lonDelta / 2
        let bbox = [
            longitude - lonDelta / 2,
            latitude - latDelta / 2,
            longitude + lonDelta / 2,
            latitude + latDelta / 2
        ]
            .map { String(format: "%.5f", $0) }
            .joined(separator: ",")

        let params = [
            ("bbox", bbox),
            ("layer", "mapnik"),
            ("marker", "\(latitude),\(longitude)")
        ]

        return descriptor(
            provider: .openStreetMap,
            sourceURL: url,
            embedURL: "https://www.openstreetmap.org/export/embed.html?\(formEncoded(params))",
            label: "OpenStreetMap",
            maxWidth: 640,
            aspectRatio: 16 / 10,
            fixedHeight: nil,
            id: "openstreetmap:\(latitude),\(longitude)@\(zoom)"
        )
    }

    // MARK: - Shared helpers

    private static func descriptor(
        provider: RichURLEmbedProvider,
        sourceURL: URL,
        embedURL: String,
        label: String,
        maxWidth: Double,
        aspectRatio: Double?,
        fixedHeight: Double?,
        id: String
    ) -> RichURLEmbedDescriptor? {
        guard let embedURL = URL(string: embedURL) else { return nil }
        return RichURLEmbedDescriptor(
            provider: provider,
            sourceURL: sourceURL,
            embedURL: embedURL,
            label: label,
            maxWidth: maxWidth,
            aspectRatio: aspectRatio,
            fixedHeight: fixedHeight,
            id: id
        )
    }

    private static func bareHost(_ host: String) -> String {
        let lowered = host.lowercased()
        for prefix in ["www.", "m.", "mobile."] where lowered.hasPrefix(prefix) {
            return String(lowered.dropFirst(prefix.count))
        }
        return lowered
    }

    private static func isPinterestHost(_ host: String) -> Bool {
        host == "pinterest.com"
            || host.hasSuffix(".pinterest.com")
            || host.hasPrefix("pinterest.")
            || host.contains(".pinterest.")
    }

    private static func pathSegments(_ url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private static func firstMatch(_ pattern: String, in value: String) -> [String]? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
                return ""
            }
            return String(value[swiftRange])
        }
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> String {
        pairs
            .map { "\(urlSearchParamEncode($0.0))=\(urlSearchParamEncode($0.1))" }
            .joined(separator: "&")
    }

    private static func urlSearchParamEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        return value.unicodeScalars.map { scalar -> String in
            if allowed.contains(scalar) {
                return String(scalar)
            }
            if scalar == " " {
                return "+"
            }
            return String(scalar.utf8.map { String(format: "%%%02X", $0) }.joined())
        }.joined()
    }
}
