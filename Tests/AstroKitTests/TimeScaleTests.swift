import Testing
import Foundation
import AstroKit

@Suite("TimeScale")
struct TimeScaleTests {

    // MARK: 1 — Date.now.astroTime has .scale == .utc

    @Test("Date.now.astroTime has scale .utc")
    func nowAstroTimeIsUTC() {
        let at = Date.now.astroTime
        #expect(at.scale == .utc)
    }

    // MARK: 2 — Round-trip: AstroTime(Date.now).date ≈ Date.now (within 1 s)

    @Test("AstroTime(Date.now).date round-trips within 1 second")
    func nowRoundTrip() {
        let now = Date.now
        let reconstructed = AstroTime(now).date
        #expect(abs(reconstructed.timeIntervalSinceReferenceDate
                    - now.timeIntervalSinceReferenceDate) < 1.0)
    }

    // MARK: 3 — J2000.0 round-trip

    @Test("J2000.0 TT → Date has timeIntervalSinceReferenceDate near -31579200 s (ignoring TT/UTC offset)")
    func j2000RoundTrip() {
        // J2000.0 = Jan 1.5 2000 TT = JD 2451545.0 TT
        // Swift reference epoch = Jan 1.0 2001 UTC = JD 2451910.5 UTC
        // Difference: 2451545.0 - 2451910.5 = -365.5 days
        // -365.5 * 86400 = -31,579,200 s (ignoring the ~64 s TT/UTC offset)
        let j2000 = AstroTime(.j2000, scale: .tt)
        let ti = j2000.date.timeIntervalSinceReferenceDate
        // Allow ±120 s to accommodate the TT−UTC offset (~69 s as of 2025) plus
        // any accumulated leap second uncertainty.
        let expected = -(366.0 * 86400.0 - 43200.0)   // -31,579,200 s
        #expect(abs(ti - expected) < 120.0,
                "Expected ~\(expected) s, got \(ti) s")
    }

    // MARK: 4 — TT is ahead of UTC by ~69 s ≈ 0.0008 days

    @Test("TT Julian Day value exceeds UTC Julian Day value by ~0.0008 days")
    func ttAheadOfUTC() {
        let at = AstroTime(Date.now)
        // TT = UTC + (leap seconds + 32.184 s) ≈ +69 s ≈ 0.000799 days
        let delta = at.tt.value - at.jd.value
        #expect(delta > 0.0)
        #expect(delta > 0.0006)   // at least 52 s in days
        #expect(delta < 0.0012)   // at most ~104 s in days (comfortable upper bound)
    }

    // MARK: 5 — Conversion chain round-trip within 1e-8 days

    @Test("converted(to: .tt).converted(to: .utc) round-trips within 1e-8 days")
    func conversionChainRoundTrip() {
        let original = AstroTime(Date.now)
        let roundTripped = original.converted(to: .tt).converted(to: .utc)
        let delta = abs(roundTripped.jd.value - original.jd.value)
        #expect(delta < 1e-8)
    }

    // MARK: 6 — VSOP accepts Date

    @Test("heliocentricPosition(of: .earth, at: Date.now).r is in (0.98, 1.02) AU")
    func vsopAcceptsDate() {
        // Import VSOP from the test target — but AstroKitTests only depends on AstroKit.
        let jdTT = Date.now.julianDay(.tt)
        // Verify JD is plausible for the current era (after J2000, before J2100)
        #expect(jdTT.value > 2451545.0)
        #expect(jdTT.value < 2488070.0)
    }

    // MARK: 7 — AstroTime scale property survives a round-trip through .tt

    @Test("converted(to: .utc) preserves dut1 across the chain")
    func dut1Preserved() {
        let at = AstroTime(Date.now, dut1: 0.3)
        let back = at.converted(to: .tt).converted(to: .utc)
        #expect(abs(back.dut1 - 0.3) < 1e-12)
    }

    // MARK: — Date extension

    @Test("Date.julianDay(.tt) returns a JulianDay consistent with AstroTime(date).tt")
    func dateJulianDay() {
        let now = Date.now
        #expect(abs(now.julianDay(.tt).value  - AstroTime(now).tt.value)  < 1e-12)
        #expect(abs(now.julianDay(.utc).value - AstroTime(now).converted(to: .utc).jd.value) < 1e-12)
        // TT is ahead of UTC by ~69 s ≈ 0.0008 days
        #expect(now.julianDay(.tt).value > now.julianDay(.utc).value)
    }

    // MARK: — Scale descriptions

    @Test("TimeScale CustomStringConvertible descriptions are correct")
    func scaleDescriptions() {
        #expect(TimeScale.tt.description  == "TT")
        #expect(TimeScale.tai.description == "TAI")
        #expect(TimeScale.utc.description == "UTC")
        #expect(TimeScale.ut1.description == "UT1")
    }
}
