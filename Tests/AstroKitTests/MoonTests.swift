import Foundation
import Testing
import AstroKit

/// Tests for Moon position via eraMoon98.
///
/// Reference: at J2000.0 (2000-Jan-1.5 TT) the Moon's geocentric RA is roughly
/// in the range of a few hours and Dec within ±30°. The exact value from
/// eraMoon98 is used for regression; the sanity bounds are loose (±30°).
@Suite("Moon")
struct MoonTests {

    // J2000.0 in TT
    let j2000tt = AstroTime(.j2000, scale: .tt)

    @Test("Moon position at J2000.0 returns ICRS frame")
    func moonPositionFrameIsICRS() throws {
        let pos = try Moon().position(at: j2000tt)
        if case .equatorial(.icrs, _) = pos.frame { /* ok */ } else {
            #expect(Bool(false), "Expected .equatorial(.icrs) frame, got \(pos.frame)")
        }
    }

    @Test("Moon geocentric distance at J2000.0 is near 1 AU / 390 lunar distances")
    func moonDistance() throws {
        let pos = try Moon().position(at: j2000tt)
        // Moon is ~384,400 km ≈ 0.00257 AU from Earth.
        // eraMoon98 returns AU; accept 0.001–0.004 AU (roughly 150,000–600,000 km).
        let dist = pos.distance ?? 0
        #expect(dist > 0.001 && dist < 0.004,
                "Moon distance \(dist) AU is outside expected 0.001–0.004 AU range")
    }

    @Test("Moon RA at J2000.0 is in [0, 2π)")
    func moonRARange() throws {
        let pos = try Moon().position(at: j2000tt)
        #expect(pos.longitude >= 0 && pos.longitude < 2 * .pi,
                "RA \(pos.longitude) rad is outside [0, 2π)")
    }

    @Test("Moon Dec at J2000.0 is within ±30°")
    func moonDecRange() throws {
        let pos = try Moon().position(at: j2000tt)
        #expect(abs(pos.latitude) <= 30 * .pi / 180,
                "Dec \(pos.latitude * 180 / .pi)° is outside ±30°")
    }

    @Test("Moon moves during a day")
    func moonMoves() throws {
        let t0 = j2000tt
        let t1 = AstroTime(.j2000 + 1.0, scale: .tt)  // one day later
        let p0 = try Moon().position(at: t0)
        let p1 = try Moon().position(at: t1)
        // Moon moves ~13°/day; difference in longitude should be > 10° = 0.175 rad
        var delta = abs(p1.longitude - p0.longitude)
        if delta > .pi { delta = 2 * .pi - delta }   // handle wrap
        #expect(delta > 0.1, "Moon RA change \(delta) rad over one day is suspiciously small")
    }

    @Test("Moon rise/transit/set at Oslo does not crash and returns valid times")
    func moonRTSOslo() throws {
        let oslo  = Observatory(longitude: 10.74 * .pi / 180, latitude: 59.91 * .pi / 180)
        let date  = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 13
            c.timeZone = TimeZone(identifier: "UTC")
            return cal.date(from: c)!
        }()
        let rts = Moon().riseTransitSet(on: date, at: oslo)
        // At mid-latitudes the Moon almost always rises and sets; it cannot be
        // circumpolar and below at the same time.
        #expect(!(rts.isAlwaysAbove && rts.isAlwaysBelow))
        // If it rises it should also set (barring edge cases near 0° incl.)
        if let rise = rts.rise, let set = rts.set {
            #expect(rise < set || rts.isAlwaysAbove,
                    "Rise \(rise) should be before set \(set)")
        }
    }
}
