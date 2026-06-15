import Foundation
import Testing
import AstroKit
@testable import VSOP

@Suite("VSOP + TimeScale")
struct VSOPTimeScaleTests {

    init() { SphericalPosition.ephemeris = VSOPEphemeris() }

    // MARK: Task spec test 6 — VSOP accepts Date

    @Test("heliocentricPosition(of: .earth, at: Date.now).distance ?? 0 is in (0.98, 1.02) AU")
    func vsopAcceptsDate() {
        let r = heliocentricPosition(of: .earth, at: Date.now).distance ?? 0
        #expect(r > 0.98)
        #expect(r < 1.02)
    }

    // MARK: Task spec test 7 — VSOP accepts AstroTime

    @Test("heliocentricPosition(of: .earth, at: AstroTime(Date.now)).distance ?? 0 is in (0.98, 1.02) AU")
    func vsopAcceptsAstroTime() {
        let r = heliocentricPosition(of: .earth, at: AstroTime(Date.now)).distance ?? 0
        #expect(r > 0.98)
        #expect(r < 1.02)
    }

    // MARK: Date and AstroTime overloads agree

    @Test("heliocentricPosition Date and AstroTime overloads return the same result")
    func dateAndAstroTimeAgreement() {
        let now = Date.now
        let rDate = heliocentricPosition(of: .earth, at: now).distance ?? 0
        let rTime = heliocentricPosition(of: .earth, at: AstroTime(now)).distance ?? 0
        #expect(abs(rDate - rTime) < 1e-12)
    }

    // MARK: heliocentricPosition → toGeocentric Date overload

    @Test("heliocentricPosition(of: .mars, at: Date.now).converted(to:) returns ecliptic frame")
    func geocentricDateOverload() throws {
        let now = Date.now
        let pos = try heliocentricPosition(of: .mars, at: now)
            .converted(to: .ecliptic(equinox: AstroTime(now).tt))
        if case .ecliptic(_, _) = pos.frame { /* ok */ } else {
            #expect(Bool(false), "Expected .ecliptic frame")
        }
    }

    // MARK: heliocentricPosition → toGeocentric AstroTime overload

    @Test("heliocentricPosition(of: .mars, at: AstroTime).converted(to:) returns ecliptic frame")
    func geocentricAstroTimeOverload() throws {
        let time = AstroTime(Date.now)
        let pos = try heliocentricPosition(of: .mars, at: time)
            .converted(to: .ecliptic(equinox: time.tt))
        if case .ecliptic(_, _) = pos.frame { /* ok */ } else {
            #expect(Bool(false), "Expected .ecliptic frame")
        }
    }

    // MARK: HeliocentricPosition

    @Test("heliocentricPosition AstroTime and JulianDay overloads agree")
    func astroTimeAndJDOverloadsAgree() {
        let now = Date.now
        let at = AstroTime(now)
        let byAstroTime = heliocentricPosition(of: .earth, at: at)
        let byJD        = heliocentricPosition(of: .earth, at: at.tt)
        #expect(byAstroTime.longitude == byJD.longitude)
        #expect(byAstroTime.latitude  == byJD.latitude)
        #expect(byAstroTime.distance  == byJD.distance)
    }
}
