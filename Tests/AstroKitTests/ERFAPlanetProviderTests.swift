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
}
