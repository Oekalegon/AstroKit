import Testing
import AstroKit

@Suite("SiderealTime")
struct SiderealTimeTests {

    // J2000.0 defined in UT1 scale so UT1 = 2451545.0 exactly, matching Meeus references.
    let j2000ut1 = AstroTime(.j2000, scale: .ut1)

    /// GMST at J2000.0 UT1: the IAU value is 18h 41m 50.54841s = 280.46061837°
    /// (Meeus "Astronomical Algorithms" 2nd ed., eq. 12.2, p. 88).
    @Test("GMST at J2000.0 (UT1) is near 280.46°")
    func gmstAtJ2000() {
        let gmst = SiderealTime(time: j2000ut1).greenwichMean
        let gmstDeg = gmst * 180.0 / .pi
        // Allow ±0.01° (≈0.04 s) — IAU 2006 vs Meeus approximation difference
        #expect(abs(gmstDeg - 280.46061837) < 0.01,
                "GMST = \(gmstDeg)°, expected ≈280.46°")
    }

    @Test("GMST and GAST differ by less than 2 arcseconds")
    func gmstGastDifference() {
        let st = SiderealTime(time: j2000ut1)
        // Equation of equinoxes is always < ±1.1″ ≈ 0.0003°; allow 0.01° for safety
        let diffDeg = abs(st.greenwichMean - st.greenwichApparent) * 180.0 / .pi
        #expect(diffDeg < 0.01, "GMST-GAST difference \(diffDeg)° exceeds 0.01°")
    }

    @Test("GMST is in [0, 2π)")
    func gmstRange() {
        for offset in stride(from: 0.0, through: 365.0, by: 30.0) {
            let t = AstroTime(.j2000 + offset, scale: .ut1)
            let gmst = SiderealTime(time: t).greenwichMean
            #expect(gmst >= 0)
            #expect(gmst < 2 * .pi)
        }
    }

    @Test("GAST advances roughly 2π per sidereal day")
    func gastAdvancesOneSiderealDay() {
        let siderealDay = 0.9972696  // sidereal day in solar days
        let g0 = SiderealTime(time: j2000ut1).greenwichApparent
        let g1 = SiderealTime(time: AstroTime(.j2000 + siderealDay, scale: .ut1)).greenwichApparent
        let delta = (g1 - g0 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        // Should be very close to 2π (i.e. delta mod 2π ≈ 0), allow ±0.001 rad
        let residual = abs(delta < .pi ? delta : delta - 2 * .pi)
        #expect(residual < 0.001, "GAST residual after one sidereal day: \(residual) rad")
    }

    @Test("Local sidereal time at Greenwich equals GAST")
    func lastAtGreenwich() {
        let greenwich = Observatory(longitude: 0.0, latitude: 51.5 * .pi / 180.0)
        let st = SiderealTime(observatory: greenwich, time: j2000ut1)
        #expect(abs(st.local - st.greenwichApparent) < 1e-10)
    }

    @Test("Local sidereal time at 90°E leads Greenwich by 6 h")
    func lastAt90East() {
        let east90 = Observatory(longitude: .pi / 2, latitude: 0.0)
        let st     = SiderealTime(observatory: east90, time: j2000ut1)
        let gast   = SiderealTime(time: j2000ut1).greenwichApparent
        let expected = (gast + .pi / 2).truncatingRemainder(dividingBy: 2 * .pi)
        #expect(abs(st.local - expected) < 1e-10)
    }

    @Test("Local sidereal time is in [0, 2π)")
    func lastRange() {
        let obs = Observatory(longitude: -74.0 * .pi / 180.0, latitude: 40.7 * .pi / 180.0)
        let last = SiderealTime(observatory: obs, time: j2000ut1).local
        #expect(last >= 0)
        #expect(last < 2 * .pi)
    }
}
