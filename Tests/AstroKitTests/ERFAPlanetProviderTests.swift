import Foundation
import Testing
import AstroKit

/// Tests for the built-in ERFA-based planet/sun provider (no VSOP required).
///
/// These tests temporarily replace the global provider with ERFAPlanetProvider
/// so they are independent of whether VSOP was registered in another test suite.
@Suite("ERFAPlanetProvider")
struct ERFAPlanetProviderTests {

    let erfa = ERFAPlanetProvider()
    let j2000 = AstroTime(.j2000, scale: .tt)

    // MARK: - Sun

    @Test("Sun distance at J2000.0 is near 1 AU")
    func sunDistance() throws {
        let pos = try erfa.sunPosition(at: j2000)
        let dist = pos.distance ?? 0
        // Earth-Sun distance varies 0.983–1.017 AU; J2000.0 is early January, near perihelion
        #expect(dist > 0.97 && dist < 1.03,
                "Sun distance \(dist) AU is outside 0.97–1.03 AU")
    }

    @Test("Sun position is in ICRS frame")
    func sunFrame() throws {
        let pos = try erfa.sunPosition(at: j2000)
        if case .equatorial(.icrs, _) = pos.frame { /* ok */ } else {
            #expect(Bool(false), "Expected .equatorial(.icrs), got \(pos.frame)")
        }
    }

    // MARK: - Planets

    @Test("Jupiter distance at J2000.0 is in the range 4–6 AU")
    func jupiterDistance() throws {
        let pos = try erfa.position(of: .jupiter, at: j2000)
        let dist = pos.distance ?? 0
        #expect(dist > 4.0 && dist < 6.5,
                "Jupiter geocentric distance \(dist) AU is outside 4–6.5 AU")
    }

    @Test("All planets (except Earth) return a non-zero position")
    func allPlanetsReturnPosition() throws {
        for body in SolarSystemBody.allCases where body != .earth {
            let pos = try erfa.position(of: body, at: j2000)
            let dist = pos.distance ?? 0
            #expect(dist > 0, "\(body.rawValue) returned zero distance")
            #expect(pos.longitude >= 0 && pos.longitude < 2 * .pi,
                    "\(body.rawValue) RA \(pos.longitude) out of range")
        }
    }

    @Test("Earth throws unsupportedTransformation")
    func earthThrows() {
        #expect(throws: AstroKitError.unsupportedTransformation) {
            _ = try erfa.position(of: .earth, at: j2000)
        }
    }

    // MARK: - Planet struct uses ERFA by default

    @Test("Planet uses ERFAPlanetProvider when no VSOP is registered")
    func planetUsesERFAByDefault() throws {
        let saved = Planet.positionProvider
        defer { Planet.positionProvider = saved }
        Planet.positionProvider = ERFAPlanetProvider()

        let pos = try Planet(.mars).position(at: j2000)
        let dist = pos.distance ?? 0
        // Mars geocentric distance varies roughly 0.4–2.7 AU
        #expect(dist > 0.3 && dist < 3.0,
                "Mars geocentric distance \(dist) AU from ERFA provider is unexpected")
    }

    @Test("Sun uses ERFAPlanetProvider when no VSOP is registered")
    func sunUsesERFAByDefault() throws {
        let saved = Planet.positionProvider
        defer { Planet.positionProvider = saved }
        Planet.positionProvider = ERFAPlanetProvider()

        let pos = try Sun().position(at: j2000)
        let dist = pos.distance ?? 0
        #expect(dist > 0.97 && dist < 1.03,
                "Sun distance \(dist) AU from ERFA provider is unexpected")
    }

    // MARK: - Night window session classification (regression for ASTR-60)

    @Test("Night window: Tromsø January 2026 polar night — isAlwaysBelow is true")
    func nightWindowTromsoJanuary2026() {
        let saved = Planet.positionProvider
        defer { Planet.positionProvider = saved }
        Planet.positionProvider = ERFAPlanetProvider()

        // Tromsø (69.65°N) is in polar night from late November through ~January 15.
        // December 21 (winter solstice) is firmly within polar night; the sun never
        // rises above the standard solar altitude during the noon-to-noon window.
        let tromso = Observatory(longitude: 18.96 * .pi / 180, latitude: 69.65 * .pi / 180)
        let iso    = ISO8601DateFormatter()

        // Frame at midnight UTC on Dec 21, anchored back 12 h → noon on Dec 20.
        let timestamp    = iso.date(from: "2025-12-21T00:00:00Z")!
        let anchoredDate = timestamp.addingTimeInterval(-43200)

        let rts = Sun().riseTransitSet(on: anchoredDate, at: tromso,
                                       window: .night, altitude: .standardAltitudeSun)

        #expect(rts.isAlwaysBelow,
                "Expected isAlwaysBelow=true during Tromsø polar night, got rise=\(String(describing: rts.rise)) set=\(String(describing: rts.set))")
        #expect(!rts.isAlwaysAbove, "isAlwaysAbove should be false during polar night")
        #expect(rts.rise == nil, "rise should be nil during polar night")
        #expect(rts.set  == nil, "set should be nil during polar night")
    }

    @Test("Night window: Tromsø July 2026 midnight sun — isAlwaysAbove is true")
    func nightWindowTromsoJuly2026() {
        let saved = Planet.positionProvider
        defer { Planet.positionProvider = saved }
        Planet.positionProvider = ERFAPlanetProvider()

        // Tromsø in July: the sun never dips below the standard solar altitude.
        let tromso = Observatory(longitude: 18.96 * .pi / 180, latitude: 69.65 * .pi / 180)
        let iso    = ISO8601DateFormatter()

        let timestamp    = iso.date(from: "2026-07-01T12:00:00Z")!
        let anchoredDate = timestamp.addingTimeInterval(-43200)

        let rts = Sun().riseTransitSet(on: anchoredDate, at: tromso,
                                       window: .night, altitude: .standardAltitudeSun)

        #expect(rts.isAlwaysAbove,
                "Expected isAlwaysAbove=true during Tromsø midnight sun, got rise=\(String(describing: rts.rise)) set=\(String(describing: rts.set))")
        #expect(!rts.isAlwaysBelow, "isAlwaysBelow should be false during midnight sun")
    }

    @Test("Night window: Oslo April 6 2026 sunset and sunrise bracket the observing night")
    func nightWindowOsloApril2026() {
        let saved = Planet.positionProvider
        defer { Planet.positionProvider = saved }
        Planet.positionProvider = ERFAPlanetProvider()

        let oslo = Observatory(longitude: 10.68306 * .pi / 180, latitude: 59.93306 * .pi / 180)
        let iso  = ISO8601DateFormatter()

        // Frame captured well after sunset (20:17 UTC = 22:17 CEST on April 6).
        let timestamp     = iso.date(from: "2026-04-06T20:17:56Z")!
        let anchoredDate  = timestamp.addingTimeInterval(-43200)   // −12 h

        let rts = Sun().riseTransitSet(on: anchoredDate, at: oslo,
                                       window: .night, altitude: .standardAltitudeSun)

        guard let sunset = rts.set, let sunrise = rts.rise else {
            #expect(Bool(false), "Expected non-nil sunset (\(String(describing: rts.set))) and sunrise (\(String(describing: rts.rise)))")
            return
        }

        // Sunset should be on April 6 between 17:30 and 18:45 UTC.
        let sunsetLo = iso.date(from: "2026-04-06T17:30:00Z")!
        let sunsetHi = iso.date(from: "2026-04-06T18:45:00Z")!
        #expect(sunset >= sunsetLo && sunset <= sunsetHi,
                "Sunset \(iso.string(from: sunset)) not in expected April 6 window")

        // Sunrise should be on April 7 between 03:30 and 04:45 UTC.
        let sunriseLo = iso.date(from: "2026-04-07T03:30:00Z")!
        let sunriseHi = iso.date(from: "2026-04-07T04:45:00Z")!
        #expect(sunrise >= sunriseLo && sunrise <= sunriseHi,
                "Sunrise \(iso.string(from: sunrise)) not in expected April 7 window")

        // Frame at 20:17 UTC must fall between sunset and sunrise.
        #expect(timestamp >= sunset && timestamp <= sunrise,
                "Frame at \(iso.string(from: timestamp)) is not between sunset \(iso.string(from: sunset)) and sunrise \(iso.string(from: sunrise))")
    }
}
