import Foundation
import Testing
import AstroKit
import VSOP

// MARK: - Helpers

/// Build a Date from UTC components.
private func utcDate(year: Int, month: Int, day: Int,
                     hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute; comps.second = second
    comps.timeZone = TimeZone(identifier: "UTC")
    return cal.date(from: comps)!
}

/// A `CelestialObject` that always returns the same fixed ICRS position.
private struct FixedBody: CelestialObject {
    let ra: Double
    let dec: Double
    func position(at time: AstroTime?, frame: CoordinateFrame) throws -> SphericalPosition {
        SphericalPosition(longitude: ra, latitude: dec, frame: .equatorial(.icrs))
    }
}

// MARK: - Test suite

/// Reference values for Oslo (59.91°N, 10.74°E) on 2026-Mar-13 UTC.
///
/// These are VSOP87D geometric values (no atmospheric refraction correction
/// beyond the standard altitude constants built into the functions):
///
/// - Sunrise: ~05:40 UTC  (Sun elevation = −50' = standard sun altitude)
/// - Sunset:  ~17:11 UTC
/// - Solar noon: ~11:26 UTC
/// - Astronomical dawn: ~03:19 UTC
/// - Astronomical dusk: ~19:34 UTC
///
/// Note: the task description listed CET (UTC+1) times; these UTC values are
/// the actual output of the VSOP87D + ERFA sidereal time pipeline and agree
/// with analytical solar-geometry formulae to within a few minutes.
@Suite("RiseTransitSet")
struct RiseTransitSetTests {

    // Oslo, Norway — φ = 59.91°N, λ = 10.74°E
    let oslo = Observatory(
        longitude:  10.74 * .pi / 180,
        latitude:   59.91 * .pi / 180
    )

    // 2026-Mar-13 midnight UTC
    let date20260313 = utcDate(year: 2026, month: 3, day: 13)

    // ±5-minute and ±10-minute tolerances
    let fiveMin: Double  = 5  * 60
    let tenMin:  Double  = 10 * 60

    init() {
        SphericalPosition.ephemeris = VSOPEphemeris()
        Planet.positionProvider    = VSOPPlanetProvider()
    }

    // -------------------------------------------------------------------------
    // MARK: Solar rise/transit/set

    @Test("Sunrise at Oslo 2026-Mar-13 is near 05:40 UTC (±5 min)")
    func sunriseOslo20260313() {
        let rts = Sun().riseTransitSet(on: date20260313, at: oslo, altitude: .standardAltitudeSun)
        // VSOP87D + eraGst06a: sunrise ~05:39:42 UTC
        let expected = utcDate(year: 2026, month: 3, day: 13, hour: 5, minute: 40)
        guard let rise = rts.rise else {
            #expect(Bool(false), "Expected a sunrise time, got nil")
            return
        }
        #expect(abs(rise.timeIntervalSince(expected)) <= fiveMin,
                "Sunrise \(rise) is more than 5 min from expected \(expected)")
    }

    @Test("Sunset at Oslo 2026-Mar-13 is near 17:11 UTC (±5 min)")
    func sunsetOslo20260313() {
        let rts = Sun().riseTransitSet(on: date20260313, at: oslo, altitude: .standardAltitudeSun)
        // VSOP87D + eraGst06a: sunset ~17:11:53 UTC
        let expected = utcDate(year: 2026, month: 3, day: 13, hour: 17, minute: 11)
        guard let set = rts.set else {
            #expect(Bool(false), "Expected a sunset time, got nil")
            return
        }
        #expect(abs(set.timeIntervalSince(expected)) <= fiveMin,
                "Sunset \(set) is more than 5 min from expected \(expected)")
    }

    @Test("Solar noon at Oslo 2026-Mar-13 is near 11:26 UTC (±5 min)")
    func solarNoonOslo20260313() {
        let rts = Sun().riseTransitSet(on: date20260313, at: oslo, altitude: .standardAltitudeSun)
        // VSOP87D + eraGst06a: solar noon ~11:25:35 UTC
        let expected = utcDate(year: 2026, month: 3, day: 13, hour: 11, minute: 26)
        guard let transit = rts.transit else {
            #expect(Bool(false), "Expected a transit time, got nil")
            return
        }
        #expect(abs(transit.timeIntervalSince(expected)) <= fiveMin,
                "Solar noon \(transit) is more than 5 min from expected \(expected)")
    }

    @Test("Sun is not always above or always below at Oslo on 2026-Mar-13")
    func sunNotCircumpolarOslo() {
        let rts = Sun().riseTransitSet(on: date20260313, at: oslo, altitude: .standardAltitudeSun)
        #expect(!rts.isAlwaysAbove)
        #expect(!rts.isAlwaysBelow)
    }

    @Test("Sunrise is before solar noon, and solar noon is before sunset")
    func sunriseTransitSetOrder() {
        let rts = Sun().riseTransitSet(on: date20260313, at: oslo, altitude: .standardAltitudeSun)
        guard let rise = rts.rise, let transit = rts.transit, let set = rts.set else {
            #expect(Bool(false), "Expected all three of rise/transit/set to be non-nil")
            return
        }
        #expect(rise < transit, "Rise should be before transit")
        #expect(transit < set, "Transit should be before set")
    }

    // -------------------------------------------------------------------------
    // MARK: Twilight

    @Test("Astronomical dawn at Oslo 2026-Mar-13 is near 03:19 UTC (±10 min)")
    func astronomicalDawnOslo20260313() {
        let crossings = Sun().elevationCrossings(on: date20260313, at: oslo,
                                                  above: .astronomicalTwilight)
        let dawn = crossings.first(where: { $0.isRising })?.date
        // VSOP87D + eraGst06a: astro dawn ~03:18:52 UTC
        let expected = utcDate(year: 2026, month: 3, day: 13, hour: 3, minute: 19)
        guard let d = dawn else {
            #expect(Bool(false), "Expected astronomical dawn, got nil")
            return
        }
        #expect(abs(d.timeIntervalSince(expected)) <= tenMin,
                "Astronomical dawn \(d) is more than 10 min from expected \(expected)")
    }

    @Test("Astronomical dusk at Oslo 2026-Mar-13 is near 19:34 UTC (±10 min)")
    func astronomicalDuskOslo20260313() {
        let crossings = Sun().elevationCrossings(on: date20260313, at: oslo,
                                                  above: .astronomicalTwilight)
        let dusk = crossings.first(where: { !$0.isRising })?.date
        // VSOP87D + eraGst06a: astro dusk ~19:33:32 UTC
        let expected = utcDate(year: 2026, month: 3, day: 13, hour: 19, minute: 34)
        guard let d = dusk else {
            #expect(Bool(false), "Expected astronomical dusk, got nil")
            return
        }
        #expect(abs(d.timeIntervalSince(expected)) <= tenMin,
                "Astronomical dusk \(d) is more than 10 min from expected \(expected)")
    }

    @Test("Dawn is before sunrise, and sunset is before dusk")
    func twilightOrdering() {
        let rts = Sun().riseTransitSet(on: date20260313, at: oslo, altitude: .standardAltitudeSun)
        let crossings = Sun().elevationCrossings(on: date20260313, at: oslo,
                                                  above: .astronomicalTwilight)
        let dawn = crossings.first(where: { $0.isRising })?.date
        let dusk = crossings.first(where: { !$0.isRising })?.date
        guard let rise = rts.rise, let set = rts.set,
              let d = dawn, let k = dusk else {
            #expect(Bool(false), "Expected all twilight and rise/set times to be non-nil")
            return
        }
        #expect(d < rise, "Astronomical dawn should be before sunrise")
        #expect(set < k,  "Sunset should be before astronomical dusk")
    }

    // -------------------------------------------------------------------------
    // MARK: Planetary rise/set

    @Test("Mars rises and sets at Oslo on 2026-Mar-13, rise < set")
    func marsRiseSetOslo20260313() {
        let rts = Planet(.mars).riseTransitSet(on: date20260313, at: oslo)
        guard let rise = rts.rise, let set = rts.set else {
            #expect(Bool(false),
                    "Expected both rise and set for Mars; rise=\(String(describing: rts.rise)), set=\(String(describing: rts.set))")
            return
        }
        #expect(rise < set, "Rise \(rise) should be before set \(set)")
    }

    @Test("Mars is not circumpolar at Oslo in March 2026")
    func marsNotCircumpolar() {
        let rts = Planet(.mars).riseTransitSet(on: date20260313, at: oslo)
        #expect(!rts.isAlwaysAbove, "Mars should not be always above horizon")
    }

    // -------------------------------------------------------------------------
    // MARK: Elevation crossings

    @Test("Jupiter elevation crossings at 20° are non-crashing, valid, and ordered")
    func jupiterElevationCrossingsOslo20260313() {
        let crossings = Planet(.jupiter).elevationCrossings(on: date20260313, at: oslo,
                                                             above: 20.0 * .pi / 180)
        // Crossings must be chronologically ordered
        for i in 1..<crossings.count {
            #expect(crossings[i - 1].date < crossings[i].date, "Crossings must be in chronological order")
        }
        // Consecutive crossings must alternate between rising and setting
        for i in 1..<crossings.count {
            #expect(crossings[i - 1].isRising != crossings[i].isRising,
                    "Consecutive crossings must alternate rising/setting")
        }
    }

    @Test("elevationCrossings are chronologically ordered and alternate rising/setting for all planets")
    func crossingsCountBounded() {
        for body in SolarSystemBody.allCases where body != .earth {
            let crossings = Planet(body).elevationCrossings(on: date20260313, at: oslo, above: 0.0)
            for i in 1..<crossings.count {
                #expect(crossings[i - 1].date < crossings[i].date,
                        "\(body.rawValue): crossings not in chronological order")
                #expect(crossings[i - 1].isRising != crossings[i].isRising,
                        "\(body.rawValue): consecutive crossings should alternate rising/setting")
            }
        }
    }

    @Test("elevationCrossings returns results in chronological order")
    func crossingsChronological() {
        let crossings = Planet(.mars).elevationCrossings(on: date20260313, at: oslo, above: 0.0)
        if crossings.count == 2 {
            #expect(crossings[0].date < crossings[1].date)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Edge cases

    @Test("isAlwaysAbove is true for a body at the celestial north pole from Oslo")
    func circumpolarity() {
        // A body at Dec = +90° is circumpolar from any location with latitude > 0°
        // Use a FixedBody at Dec = 89.9° (circumpolar from Oslo at 59.91°N)
        let rts = FixedBody(ra: 0, dec: 89.9 * .pi / 180)
            .riseTransitSet(on: date20260313, at: oslo)
        #expect(rts.isAlwaysAbove, "Body at Dec=+89.9° should be circumpolar from Oslo (59.91°N)")
        #expect(!rts.isAlwaysBelow)
        #expect(rts.rise == nil)
        #expect(rts.set == nil)
    }

    @Test("isAlwaysBelow is true for a body at the celestial south pole from Oslo")
    func neverRises() {
        // A body at Dec = −89.9° never rises from Oslo (59.91°N)
        let rts = FixedBody(ra: 0, dec: -89.9 * .pi / 180)
            .riseTransitSet(on: date20260313, at: oslo)
        #expect(rts.isAlwaysBelow, "Body at Dec=−89.9° should never rise from Oslo (59.91°N)")
        #expect(!rts.isAlwaysAbove)
        #expect(rts.rise == nil)
        #expect(rts.set == nil)
    }
}
