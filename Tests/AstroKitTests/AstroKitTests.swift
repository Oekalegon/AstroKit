import Testing
import AstroKit

@Suite("AstroKit")
struct AstroKitTests {

    let j2000: JulianDay = .j2000

    // Vega (α Lyr): ICRS RA 279.23473°, Dec +38.78369°  (Hipparcos, epoch 1991.25)
    var vegaICRS: SphericalPosition {
        SphericalPosition(
            longitude: 279.23473 * .pi / 180.0,
            latitude:  38.78369  * .pi / 180.0,
            frame: .equatorial(.icrs)
        )
    }

    @Test("ICRS → galactic round-trip")
    func icrsToGalacticRoundTrip() throws {
        let gal   = try vegaICRS.converted(to: .galactic())
        let back  = try gal.converted(to: .equatorial(.icrs))

        #expect(abs(back.longitude - vegaICRS.longitude) < 1e-9)
        #expect(abs(back.latitude  - vegaICRS.latitude)  < 1e-9)
    }

    @Test("ICRS → ecliptic round-trip")
    func icrsToEclipticRoundTrip() throws {
        let ecl  = try vegaICRS.converted(to: .ecliptic(equinox: j2000))
        let back = try ecl.converted(to: .equatorial(.icrs))

        #expect(abs(back.longitude - vegaICRS.longitude) < 1e-9)
        #expect(abs(back.latitude  - vegaICRS.latitude)  < 1e-9)
    }

    @Test("ICRS → CIRS produces different coordinates")
    func icrsToCIRS() throws {
        let cirs = try vegaICRS.converted(to: .equatorial(.cirs(jd: j2000)))
        // CIRS ≠ ICRS (precession/aberration shifts the position)
        let deltaRA = abs(cirs.longitude - vegaICRS.longitude)
        #expect(deltaRA > 0)
    }

    @Test("ICRS → horizontal returns elevation in expected range")
    func icrsToHorizontal() throws {
        // Greenwich, midnight at J2000.0
        let greenwich = Observatory(longitude: 0.0, latitude: 51.5 * .pi / 180.0)
        let hz = try vegaICRS.converted(
            to: .horizontal(observer: greenwich, jd: j2000, refracted: false)
        )
        // Elevation must be in [-π/2, π/2]
        #expect(hz.latitude >= -.pi / 2)
        #expect(hz.latitude <=  .pi / 2)
        // Azimuth must be in [0, 2π]
        #expect(hz.longitude >= 0)
        #expect(hz.longitude <= 2 * .pi)
    }

    @Test("position(at: nil, frame: .horizontal) infers time from frame JD")
    func horizontalTimeInference() throws {
        // A CatalogueObject asked for its position with nil time + horizontal frame
        // should use the JD embedded in the horizontal frame.
        let greenwich = Observatory(longitude: 0.0, latitude: 51.5 * .pi / 180.0)
        let vega = CatalogueObject(
            position: vegaICRS,
            epoch: 2000.0
        )
        let frame = CoordinateFrame.horizontal(observer: greenwich, jd: j2000, refracted: false)
        // Should succeed — no explicit time, JD comes from frame
        let pos = try vega.position(at: nil, frame: frame)
        #expect(pos.latitude >= -.pi / 2)
        #expect(pos.latitude <=  .pi / 2)
    }

    @Test("position with conflicting explicit time and horizontal JD throws")
    func horizontalConflictingTimesThrows() throws {
        let greenwich = Observatory(longitude: 0.0, latitude: 51.5 * .pi / 180.0)
        let vega = CatalogueObject(
            position: vegaICRS,
            epoch: 2000.0
        )
        // j2000 is 2000-Jan-01; use a time 1 year later — clearly different
        let oneYearLater = AstroTime(j2000 + 365.25, scale: .utc)
        let frame = CoordinateFrame.horizontal(observer: greenwich, jd: j2000, refracted: false)
        #expect(throws: AstroKitError.conflictingTimes) {
            _ = try vega.position(at: oneYearLater as AstroTime?, frame: frame)
        }
    }

    @Test("CatalogueObject propagation changes position for high-PM star")
    func cataloguePropagation() {
        // Barnard's star: μ_α* ≈ −798 mas/yr, μ_δ ≈ +10328 mas/yr — highest known PM
        let barnard = CatalogueObject(
            position: SphericalPosition(
                longitude: 269.45402 * .pi / 180.0,
                latitude:   4.66828  * .pi / 180.0,
                frame: .equatorial(.icrs)
            ),
            epoch: 2000.0,
            properMotion: ProperMotion(ra: -798.71, dec: 10337.77),
            parallax: 547.45,
            radialVelocity: -110.6
        )
        let propagated = barnard.propagated(toEpoch: 2050.0)
        // 50 years × ~10 arcsec/yr ≈ 500 arcsec shift in Dec
        let dDec = abs(propagated.catalogPosition.latitude - barnard.catalogPosition.latitude)
        #expect(dDec > 0.001)  // at least 0.001 radians ≈ 3.4°
    }
}
