import Testing
import Foundation
@testable import AstrophotoArchiveKit

// Writes a single-block FITS file containing one pair of site coordinate keywords.
private func writeSiteFITS(
    latKeyword: String, lonKeyword: String,
    lat: Double, lon: Double
) throws -> URL {
    let url = tempFITSURL("site-kw")
    var block = Data(repeating: 32, count: 2880)

    func card(_ text: String, slot: Int) {
        let padded = text.padding(toLength: 80, withPad: " ", startingAt: 0)
        for (i, byte) in padded.utf8.prefix(80).enumerated() {
            block[slot * 80 + i] = byte
        }
    }

    // Pad keyword to exactly 8 characters so the = lands in column 9.
    func kw(_ name: String) -> String { name.padding(toLength: 8, withPad: " ", startingAt: 0) }

    card("SIMPLE  =                    T / conforms to FITS standard", slot: 0)
    card("BITPIX  =                   16 / bits per pixel", slot: 1)
    card("NAXIS   =                    0 / no data array", slot: 2)
    card("IMAGETYP= 'Light Frame'", slot: 3)
    card("DATE-OBS= '2026-04-06T20:17:00'", slot: 4)
    card("EXPTIME =                300.0 / exposure in seconds", slot: 5)
    card(String(format: "\(kw(latKeyword))= %24.6f / site latitude", lat), slot: 6)
    card(String(format: "\(kw(lonKeyword))= %24.6f / site longitude", lon), slot: 7)
    card("END", slot: 8)

    try block.write(to: url)
    return url
}

@Suite("FITSHeaderReader — site coordinate keyword variants")
struct SiteCoordinateParsingTests {

    private let expectedLat =  59.93
    private let expectedLon =  10.68

    @Test("SITELAT / SITELONG parsed correctly (KStars/EKOS, N.I.N.A., SGP)")
    func sitelatSitelong() throws {
        let url = try writeSiteFITS(latKeyword: "SITELAT", lonKeyword: "SITELONG",
                                    lat: expectedLat, lon: expectedLon)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(abs((meta.siteLatitude  ?? .nan) - expectedLat) < 0.001)
        #expect(abs((meta.siteLongitude ?? .nan) - expectedLon) < 0.001)
    }

    @Test("GPS-LAT / GPS-LON parsed correctly (Telescope Live / QHY GPS cameras)")
    func gpsLatGpsLon() throws {
        let url = try writeSiteFITS(latKeyword: "GPS-LAT", lonKeyword: "GPS-LON",
                                    lat: expectedLat, lon: expectedLon)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(abs((meta.siteLatitude  ?? .nan) - expectedLat) < 0.001)
        #expect(abs((meta.siteLongitude ?? .nan) - expectedLon) < 0.001)
    }

    @Test("LAT-OBS / LONG-OBS parsed correctly (older convention)")
    func latObsLongObs() throws {
        let url = try writeSiteFITS(latKeyword: "LAT-OBS", lonKeyword: "LONG-OBS",
                                    lat: expectedLat, lon: expectedLon)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(abs((meta.siteLatitude  ?? .nan) - expectedLat) < 0.001)
        #expect(abs((meta.siteLongitude ?? .nan) - expectedLon) < 0.001)
    }

    @Test("OBSGEO-B / OBSGEO-L parsed correctly (formal FITS/WCS standard)")
    func obsgeoB() throws {
        let url = try writeSiteFITS(latKeyword: "OBSGEO-B", lonKeyword: "OBSGEO-L",
                                    lat: expectedLat, lon: expectedLon)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(abs((meta.siteLatitude  ?? .nan) - expectedLat) < 0.001)
        #expect(abs((meta.siteLongitude ?? .nan) - expectedLon) < 0.001)
    }

    @Test("West-positive longitude from GPS-LON is preserved as-is (east-positive convention)")
    func gpsLonNegativeForWest() throws {
        // Telescope Live / QHY cameras in Spain: GPS-LON = -2.4087 (west, east-positive)
        let url = try writeSiteFITS(latKeyword: "GPS-LAT", lonKeyword: "GPS-LON",
                                    lat: 37.501, lon: -2.409)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect((meta.siteLongitude ?? 0) < 0, "West-of-Greenwich longitude must be stored as negative")
        #expect(abs((meta.siteLongitude ?? .nan) - (-2.409)) < 0.001)
    }

    @Test("FITS file with no site keywords returns nil for both coordinates")
    func noSiteKeywords() throws {
        let url = tempFITSURL("no-site")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTinyFITS(to: url)

        let meta = try FITSHeaderReader.read(from: url.path)
        #expect(meta.siteLatitude  == nil)
        #expect(meta.siteLongitude == nil)
    }
}
