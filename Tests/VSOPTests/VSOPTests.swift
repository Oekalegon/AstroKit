import Foundation
import Testing
import AstroKit
@testable import VSOP

@Suite("VSOP")
struct VSOPTests {

    init() {
        SphericalPosition.ephemeris = VSOPEphemeris()
        Planet.positionProvider    = VSOPPlanetProvider()
    }

    // J2000.0 = JDE 2451545.0
    let j2000: JulianDay = .j2000

    // -------------------------------------------------------------------------
    // MARK: Earth sanity checks

    @Test("Earth radius vector is near 1 AU at J2000.0")
    func earthRadiusAtJ2000() {
        let pos = heliocentricPosition(of: .earth, at: j2000)
        // Earth perihelion ≈ 0.9833 AU, aphelion ≈ 1.0167 AU
        #expect((pos.distance ?? 0) > 0.980)
        #expect((pos.distance ?? 0) < 1.020)
    }

    @Test("Earth radius vector completes annual range over one year")
    func earthRadiusRange() {
        let step = 30.0   // days
        var rMin = Double.infinity
        var rMax = -Double.infinity
        for i in 0 ..< 13 {
            let jd = j2000 + Double(i) * step
            let r = heliocentricPosition(of: .earth, at: jd).distance ?? 0
            rMin = min(rMin, r)
            rMax = max(rMax, r)
        }
        // Over ~a year the range should span at least 0.03 AU (ecc ≈ 0.017 → Δr ≈ 0.034)
        #expect(rMax - rMin > 0.03)
    }

    @Test("Earth longitude advances ~2π in one sidereal year")
    func earthLongitudeAdvance() {
        let siderealYear = 365.25636  // days
        let p0 = heliocentricPosition(of: .earth, at: j2000)
        let p1 = heliocentricPosition(of: .earth, at: j2000 + siderealYear)
        let delta = (p1.longitude - p0.longitude + 4 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        // Should be very close to 2π (i.e. Δ mod 2π ≈ 0, so within a few arcsec)
        let residual = abs(delta < .pi ? delta : delta - 2 * .pi)
        #expect(residual < 0.001)  // < 0.06°
    }

    @Test("Earth ecliptic latitude stays very small")
    func earthLatitudeSmall() {
        // Earth's ecliptic latitude is defined as 0 in the ecliptic-of-date frame,
        // so VSOP87D B should be essentially zero (< 0.0001 rad ≈ 0.006°).
        let b = heliocentricPosition(of: .earth, at: j2000).latitude
        #expect(abs(b) < 0.0002)
    }

    // -------------------------------------------------------------------------
    // MARK: Geocentric Sun longitude — independent cross-check

    /// VSOP87D Earth heliocentric longitude + π gives the Sun's geocentric ecliptic
    /// longitude.  We verify this against well-known approximate solar positions.

    /// 1992 April 12: Sun is in late Aries, geocentric ecliptic longitude ≈ 22°.
    @Test("Earth at 1992-Apr-12: Sun geocentric longitude ≈ 22° (late Aries)")
    func sunLongitudeApril1992() {
        let jde1992Apr12: JulianDay = 2448724.5
        let earth = heliocentricPosition(of: .earth, at: jde1992Apr12)
        // Sun geocentric longitude = Earth heliocentric longitude + π (mod 2π)
        let twoPi = 2.0 * Double.pi
        let sunLon = (earth.longitude + .pi).truncatingRemainder(dividingBy: twoPi)
        let sunLonDeg = sunLon * 180.0 / .pi
        // Sun should be near 22° (late Aries), allowing ±3° for VSOP truncation
        #expect(sunLonDeg > 19)
        #expect(sunLonDeg < 25)
        // Earth should be near 1 AU in April (heading toward aphelion in July)
        #expect((earth.distance ?? 0) > 1.000)
        #expect((earth.distance ?? 0) < 1.010)
    }

    /// 2000 July 4 (aphelion): Sun near 102°, Earth R ≈ 1.0167 AU.
    @Test("Earth at 2000-Jul-04: near aphelion, Sun near 102°")
    func earthAphelion() {
        let jdeAphelion: JulianDay = 2451730.0  // 2000 Jul 4 ≈ JDE 2451730
        let earth = heliocentricPosition(of: .earth, at: jdeAphelion)
        let twoPi = 2.0 * Double.pi
        let sunLon = (earth.longitude + .pi).truncatingRemainder(dividingBy: twoPi)
        let sunLonDeg = sunLon * 180.0 / .pi
        // Sun should be near 102° (Cancer/Gemini boundary), Earth R ≈ 1.0167 AU
        #expect(sunLonDeg > 98)
        #expect(sunLonDeg < 106)
        #expect((earth.distance ?? 0) > 1.013)
        #expect((earth.distance ?? 0) < 1.020)
    }

    // -------------------------------------------------------------------------
    // MARK: Orbital radius range checks for all planets

    @Test("Mercury mean radius is ~0.387 AU")
    func mercuryRadius() {
        let r = heliocentricPosition(of: .mercury, at: j2000).distance ?? 0
        #expect(r > 0.30 && r < 0.48)
    }

    @Test("Venus mean radius is ~0.723 AU")
    func venusRadius() {
        let r = heliocentricPosition(of: .venus, at: j2000).distance ?? 0
        #expect(r > 0.71 && r < 0.73)
    }

    @Test("Mars mean radius is ~1.52 AU")
    func marsRadius() {
        let r = heliocentricPosition(of: .mars, at: j2000).distance ?? 0
        #expect(r > 1.38 && r < 1.67)
    }

    @Test("Jupiter mean radius is ~5.2 AU")
    func jupiterRadius() {
        let r = heliocentricPosition(of: .jupiter, at: j2000).distance ?? 0
        #expect(r > 4.95 && r < 5.46)
    }

    @Test("Saturn mean radius is ~9.5 AU")
    func saturnRadius() {
        let r = heliocentricPosition(of: .saturn, at: j2000).distance ?? 0
        #expect(r > 9.0 && r < 10.1)
    }

    @Test("Uranus mean radius is ~19.2 AU")
    func uranusRadius() {
        let r = heliocentricPosition(of: .uranus, at: j2000).distance ?? 0
        #expect(r > 18.3 && r < 20.1)
    }

    @Test("Neptune mean radius is ~30.1 AU")
    func neptuneRadius() {
        let r = heliocentricPosition(of: .neptune, at: j2000).distance ?? 0
        #expect(r > 29.8 && r < 30.4)
    }

    // -------------------------------------------------------------------------
    // MARK: Longitude always in [0, 2π)

    @Test("heliocentricPosition returns longitude in [0, 2π) for all planets")
    func longitudeRange() {
        for body in SolarSystemBody.allCases {
            let l = heliocentricPosition(of: body, at: j2000).longitude
            #expect(l >= 0)
            #expect(l < 2 * .pi)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Geocentric ecliptic

    @Test("heliocentricPosition → converted(to:) returns SphericalPosition in .ecliptic frame")
    func geocentricEclipticFrame() throws {
        let pos = try heliocentricPosition(of: .mars, at: j2000)
            .converted(to: .ecliptic(equinox: j2000))
        if case .ecliptic(_, _) = pos.frame { /* ok */ } else {
            #expect(Bool(false), "Expected .ecliptic frame")
        }
    }

    @Test("Mars geocentric distance is between 0.37 and 2.67 AU")
    func marsGeocentricDistance() throws {
        let pos = try heliocentricPosition(of: .mars, at: j2000)
            .converted(to: .ecliptic(equinox: j2000))
        // Min opposition ≈ 0.37 AU, max conjunction ≈ 2.67 AU
        #expect((pos.distance ?? 0) > 0.37)
        #expect((pos.distance ?? 0) < 2.67)
    }

    @Test("heliocentricPosition.asSphericalPosition wraps into .ecliptic frame")
    func heliocentricAsSphericalPosition() {
        let hp = heliocentricPosition(of: .earth, at: j2000)
        let sp = hp
        #expect(sp.longitude == hp.longitude)
        #expect(sp.latitude  == hp.latitude)
        #expect(sp.distance  == (hp.distance ?? 0))
        if case .ecliptic(_, _) = sp.frame { /* ok */ } else {
            #expect(Bool(false), "Expected .ecliptic frame")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Orbital periods

    @Test("Earth heliocentric longitude advances ~2π in one sidereal year")
    func earthPeriod() {
        let siderealYear = 365.25636  // days
        let p0 = heliocentricPosition(of: .earth, at: j2000)
        let p1 = heliocentricPosition(of: .earth, at: j2000 + siderealYear)
        let delta = (p1.longitude - p0.longitude + 4 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let residual = abs(delta < .pi ? delta : delta - 2 * .pi)
        #expect(residual < 0.001)  // < 0.06°
    }

    @Test("Jupiter heliocentric longitude advances ~2π in one sidereal period")
    func jupiterPeriod() {
        let jupiterPeriod = 4332.589  // days ≈ 11.862 yr
        let p0 = heliocentricPosition(of: .jupiter, at: j2000)
        let p1 = heliocentricPosition(of: .jupiter, at: j2000 + jupiterPeriod)
        let delta = (p1.longitude - p0.longitude + 4 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let residual = abs(delta < .pi ? delta : delta - 2 * .pi)
        #expect(residual < 0.01)  // < 0.6°
    }

    // -------------------------------------------------------------------------
    // MARK: Ephemeris reference positions — arcsecond precision

    /// 1 arcsecond in radians.
    private let arcsec = Double.pi / 648_000.0

    /// Helper: shortest signed angular difference (result in (−π, π]).
    private func angDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d >  .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    /// Meeus "Astronomical Algorithms" 2nd ed., Example 25.a (p. 163):
    /// Venus heliocentric ecliptic at JDE 2448976.5 (1992 Dec 20.0 TD).
    /// Full VSOP87D: L = 26.11412°, B = −2.62070°, R = 0.724603 AU.
    /// The Appendix II truncated tables should agree to within ~1".
    @Test("Venus heliocentric at 1992-Dec-20 matches Meeus Example 25.a to 10\"")
    func venusHeliocentricMeeus() {
        let jde: JulianDay = 2448976.5
        let pos = heliocentricPosition(of: .venus, at: jde)
        let expectedL = 26.11412 * .pi / 180.0
        let expectedB = -2.62070 * .pi / 180.0
        #expect(abs(angDiff(pos.longitude, expectedL)) < 10 * arcsec)
        #expect(abs(pos.latitude - expectedB)         < 10 * arcsec)
        #expect(abs((pos.distance ?? 0) - 0.724603)          < 0.00001)      // < 1500 km (Meeus Appendix II accuracy)
    }

    /// Mars geocentric ecliptic at 2003 Aug 28 (JDE 2452880.0): record-close opposition.
    /// RA 22h 39m, Dec −15.8° → ecliptic longitude ≈ 335.4° (obliquity ε ≈ 23.44°).
    /// Published distance = 0.37272 AU.
    @Test("Mars geocentric at 2003-Aug-28 record opposition to 30'")
    func marsOpposition2003() throws {
        let jde: JulianDay = 2452880.0
        let pos = try heliocentricPosition(of: .mars, at: jde)
            .converted(to: .ecliptic(equinox: jde))
        #expect(abs(angDiff(pos.longitude, 335.4 * .pi / 180.0)) < 30 * 60 * arcsec) // 30 arcmin
        #expect(abs((pos.distance ?? 0) - 0.37272)                < 0.001)            // ~150 000 km
    }

    // -------------------------------------------------------------------------
    // MARK: JPL Horizons verification (2026 Mars, DE441, geocentric)

    /// Geocentric ICRF positions from JPL Horizons (DE441, UT).
    ///
    /// Two systematic offsets prevent arcsecond comparison against JPL's
    /// *apparent* ICRF positions:
    ///  - Light-travel-time: ~19 min at 2.3 AU × ~1.97"/min ≈ 38"
    ///  - Annual aberration: up to ~20" depending on geometry
    ///
    /// Geometric vs. apparent therefore differs ~50–60" for Mars at 2.3 AU.
    /// Distance Δ is practically frame-independent (< 0.01% effect from
    /// aberration), so its tolerance is tight.  Angular tolerance is 2' to
    /// accommodate the systematic geometric/apparent offset plus VSOP
    /// truncation (~1–10") and UT/TT (ΔT ≈ 72 s → < 3").
    @Test("Mars geocentric distance matches JPL Horizons to 0.001 AU")
    func marsDistanceJPL() {
        // (JDE, Horizons delta AU)
        let rows: [(JulianDay, Double)] = [
            (2461112.5, 2.32389741687536),  // 2026-Mar-13 00:00 UT
            (2461128.5, 2.29967488492439),  // 2026-Mar-29 00:00 UT
            (2461142.5, 2.27759074172528),  // 2026-Apr-12 00:00 UT
        ]
        for (jde, refDist) in rows {
            let dist = (try? heliocentricPosition(of: .mars, at: jde)
                .converted(to: .ecliptic(equinox: jde)))!.distance ?? 0
            #expect(abs(dist - refDist) < 0.001,
                    "JDE \(jde.value): dist error \(abs(dist - refDist)) AU")
        }
    }

    @Test("Mars geocentric ICRS position matches JPL Horizons apparent to 2'")
    func marsAngularJPL() throws {
        // (JDE, RA rad, Dec rad)  from JPL Horizons apparent ICRF
        let arcmin = 60.0 * arcsec
        let rows: [(JulianDay, Double, Double)] = [
            (2461112.5,   // 2026-Mar-13: RA 22h 39m 40.12s, Dec −09° 38' 25.2"
             (22 + 39/60.0 + 40.12/3600) * 15 * .pi/180,
             -(9 + 38/60.0 + 25.2/3600) * .pi/180),
            (2461128.5,   // 2026-Mar-29: RA 23h 26m 24.17s, Dec −04° 46' 11.1"
             (23 + 26/60.0 + 24.17/3600) * 15 * .pi/180,
             -(4 + 46/60.0 + 11.1/3600) * .pi/180),
            (2461142.5,   // 2026-Apr-12: RA 00h 06m 29.43s, Dec −00° 23' 05.6"
             ( 0 +  6/60.0 + 29.43/3600) * 15 * .pi/180,
             -(0 + 23/60.0 +  5.6/3600) * .pi/180),
        ]
        for (jde, refRA, refDec) in rows {
            let icrs     = try heliocentricPosition(of: .mars, at: jde)
                .converted(to: .equatorial(.icrs))
            let raSkySep = abs(angDiff(icrs.longitude, refRA)) * cos(refDec)
            let decSep   = abs(icrs.latitude - refDec)
            #expect(raSkySep < 2 * arcmin, "JDE \(jde.value): RA sky-error \(raSkySep / arcsec)\"")
            #expect(decSep   < 2 * arcmin, "JDE \(jde.value): Dec error \(decSep / arcsec)\"")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: JPL Horizons verification (2026 Neptune, DE441, geocentric)

    /// Same systematic offsets as for Mars apply, but scaled to Neptune's
    /// distance (~30.87 AU):
    ///  - Light-travel-time: ~257 min × ~0.094"/min ≈ 24"
    ///  - Annual aberration: ~20"
    /// Combined geometric vs. apparent ≈ 44". 2' tolerance is comfortable.
    /// ΔT ≈ 72 s at Neptune's sky-rate (0.094"/min) contributes < 0.2".
    /// Residual ~7e-5 AU after switching to the complete VSOP87D series.
    /// VSOP87D was fitted to DE200; JPL Horizons uses DE441 — the ~10 000 km
    /// offset is a theory-vs-ephemeris systematic, not a truncation issue.
    @Test("Neptune geocentric distance matches JPL Horizons to 0.0001 AU")
    func neptuneDistanceJPL() {
        let rows: [(JulianDay, Double)] = [
            (2461112.5, 30.8637215121985),  // 2026-Mar-13 00:00 UT
            (2461122.5, 30.8790274400799),  // 2026-Mar-23 00:00 UT (near opposition)
            (2461142.5, 30.8249812745753),  // 2026-Apr-12 00:00 UT
        ]
        for (jde, refDist) in rows {
            let dist = (try? heliocentricPosition(of: .neptune, at: jde)
                .converted(to: .ecliptic(equinox: jde)))!.distance ?? 0
            #expect(abs(dist - refDist) < 0.0001,
                    "JDE \(jde.value): dist error \(abs(dist - refDist)) AU")
        }
    }

    @Test("Neptune geocentric ICRS position matches JPL Horizons apparent to 2'")
    func neptuneAngularJPL() throws {
        let arcmin = 60.0 * arcsec
        let rows: [(JulianDay, Double, Double)] = [
            (2461112.5,   // 2026-Mar-13: RA 00h 06m 12.10s, Dec −00° 45' 05.2"
             ( 0 +  6/60.0 + 12.10/3600) * 15 * .pi/180,
             -(0 + 45/60.0 +  5.2/3600) * .pi/180),
            (2461122.5,   // 2026-Mar-23: RA 00h 07m 35.35s, Dec −00° 36' 06.1"
             ( 0 +  7/60.0 + 35.35/3600) * 15 * .pi/180,
             -(0 + 36/60.0 +  6.1/3600) * .pi/180),
            (2461142.5,   // 2026-Apr-12: RA 00h 10m 19.95s, Dec −00° 18' 34.6"
             ( 0 + 10/60.0 + 19.95/3600) * 15 * .pi/180,
             -(0 + 18/60.0 + 34.6/3600) * .pi/180),
        ]
        for (jde, refRA, refDec) in rows {
            let icrs     = try heliocentricPosition(of: .neptune, at: jde)
                .converted(to: .equatorial(.icrs))
            let raSkySep = abs(angDiff(icrs.longitude, refRA)) * cos(refDec)
            let decSep   = abs(icrs.latitude - refDec)
            #expect(raSkySep < 2 * arcmin, "JDE \(jde.value): RA sky-error \(raSkySep / arcsec)\"")
            #expect(decSep   < 2 * arcmin, "JDE \(jde.value): Dec error \(decSep / arcsec)\"")
        }
    }
}
