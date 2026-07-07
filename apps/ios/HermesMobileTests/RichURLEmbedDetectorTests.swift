import XCTest
@testable import HermesMobile

final class RichURLEmbedDetectorTests: XCTestCase {
    func testYoutuBeURLBuildsNoCookieEmbed() throws {
        let embed = try XCTUnwrap(RichURLEmbedDetector.detect("https://youtu.be/dQw4w9WgXcQ"))

        XCTAssertEqual(embed.provider, .youtube)
        XCTAssertEqual(embed.id, "youtube:dQw4w9WgXcQ")
        XCTAssertEqual(embed.label, "YouTube")
        XCTAssertEqual(embed.maxWidth, 640)
        XCTAssertEqual(embed.aspectRatio, 16 / 9)
        XCTAssertNil(embed.fixedHeight)
        XCTAssertEqual(embed.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0")
    }

    func testYouTubeWatchURLUsesVParameter() throws {
        let embed = try XCTUnwrap(RichURLEmbedDetector.detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))

        XCTAssertEqual(embed.id, "youtube:dQw4w9WgXcQ")
        XCTAssertEqual(embed.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0")
    }

    func testYouTubeShortsAndLivePaths() throws {
        let shorts = try XCTUnwrap(RichURLEmbedDetector.detect("https://youtube.com/shorts/dQw4w9WgXcQ"))
        let live = try XCTUnwrap(RichURLEmbedDetector.detect("https://youtube.com/live/dQw4w9WgXcQ"))

        XCTAssertEqual(shorts.id, "youtube:dQw4w9WgXcQ")
        XCTAssertEqual(live.id, "youtube:dQw4w9WgXcQ")
    }

    func testYouTubeInvalidIdsAreUnsupported() {
        XCTAssertNil(RichURLEmbedDetector.detect("https://youtu.be/too-short"))
        XCTAssertNil(RichURLEmbedDetector.detect("https://youtube.com/watch?v=not_valid!!!!"))
    }

    func testYouTubeStartTimeAcceptsClockAndSecondsForms() throws {
        let clock = try XCTUnwrap(RichURLEmbedDetector.detect("https://youtu.be/dQw4w9WgXcQ?t=1m30s"))
        let seconds = try XCTUnwrap(RichURLEmbedDetector.detect("https://youtube.com/watch?v=dQw4w9WgXcQ&start=90"))

        XCTAssertEqual(clock.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0&start=90")
        XCTAssertEqual(seconds.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0&start=90")
    }

    func testSpotifyLocalePrefixUsesCompactEmbed() throws {
        let embed = try XCTUnwrap(RichURLEmbedDetector.detect("https://open.spotify.com/intl-de/track/6rqhFgbbKwnb9MLmUQDhG6"))

        XCTAssertEqual(embed.provider, .spotify)
        XCTAssertEqual(embed.id, "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
        XCTAssertEqual(embed.label, "Spotify")
        XCTAssertEqual(embed.maxWidth, 480)
        XCTAssertNil(embed.aspectRatio)
        XCTAssertEqual(embed.fixedHeight, 152)
        XCTAssertEqual(embed.embedURL.absoluteString, "https://open.spotify.com/embed/track/6rqhFgbbKwnb9MLmUQDhG6")
    }

    func testSpotifyUnsupportedTypeIsIgnored() {
        XCTAssertNil(RichURLEmbedDetector.detect("https://open.spotify.com/user/example"))
    }

    func testGoogleMapsQueryAndPlaceURLs() throws {
        let query = try XCTUnwrap(RichURLEmbedDetector.detect("https://www.google.com/maps?q=Empire+State+Building"))
        let place = try XCTUnwrap(RichURLEmbedDetector.detect("https://www.google.com/maps/place/Empire+State+Building/@40.7484,-73.9857,17z"))

        XCTAssertEqual(query.provider, .googleMaps)
        XCTAssertEqual(query.id, "googlemaps:Empire State Building")
        XCTAssertEqual(query.embedURL.absoluteString, "https://maps.google.com/maps?output=embed&q=Empire+State+Building")
        XCTAssertEqual(place.id, "googlemaps:40.7484,-73.9857@17")
        XCTAssertEqual(place.embedURL.absoluteString, "https://maps.google.com/maps?output=embed&q=40.7484%2C-73.9857&z=17")
    }

    func testGoogleMapsCoordinatesAndZoom() throws {
        let embed = try XCTUnwrap(RichURLEmbedDetector.detect("https://maps.google.com/maps/@37.7749,-122.4194,12.3z"))

        XCTAssertEqual(embed.label, "Google Maps")
        XCTAssertEqual(embed.maxWidth, 640)
        XCTAssertEqual(embed.aspectRatio, 16 / 10)
        XCTAssertNil(embed.fixedHeight)
        XCTAssertEqual(embed.id, "googlemaps:37.7749,-122.4194@12")
        XCTAssertEqual(embed.embedURL.absoluteString, "https://maps.google.com/maps?output=embed&q=37.7749%2C-122.4194&z=12")
    }

    func testOpenStreetMapHashMapBuildsBBoxEmbed() throws {
        let embed = try XCTUnwrap(RichURLEmbedDetector.detect("https://www.openstreetmap.org/#map=12/37.7749/-122.4194"))

        XCTAssertEqual(embed.provider, .openStreetMap)
        XCTAssertEqual(embed.id, "openstreetmap:37.7749,-122.4194@12.0")
        XCTAssertEqual(embed.label, "OpenStreetMap")
        XCTAssertEqual(embed.maxWidth, 640)
        XCTAssertEqual(embed.aspectRatio, 16 / 10)
        XCTAssertNil(embed.fixedHeight)
        XCTAssertEqual(embed.embedURL.absoluteString, "https://www.openstreetmap.org/export/embed.html?bbox=-122.46335%2C37.75293%2C-122.37545%2C37.79687&layer=mapnik&marker=37.7749%2C-122.4194")
    }

    func testUnsupportedAndNonHTTPURLsReturnNil() {
        XCTAssertNil(RichURLEmbedDetector.detect("ftp://youtu.be/dQw4w9WgXcQ"))
        XCTAssertNil(RichURLEmbedDetector.detect("notaurl"))
        XCTAssertNil(RichURLEmbedDetector.detect("https://vimeo.com/123456789"))
        XCTAssertNil(RichURLEmbedDetector.detect("https://example.com/maps?q=Empire+State+Building"))
    }
}
