import AstroKit
import Foundation

// MARK: - heliocentricPosition (internal)

/// Compute the heliocentric ecliptic position of a solar system body using VSOP87D.
///
/// Internal to the VSOP module — consumers use ``Planet`` or ``VSOPPlanetProvider``.
func heliocentricPosition(of body: SolarSystemBody, at jd: JulianDay) -> SphericalPosition {
    let tau = (jd.value - 2451545.0) / 365250.0  // Julian millennia from J2000.0
    let (l, b, r) = body.vsopSeries.evaluate(tau: tau)
    let twoPi = 2.0 * Double.pi
    let lNorm = l.truncatingRemainder(dividingBy: twoPi)
    return SphericalPosition(
        longitude: lNorm < 0 ? lNorm + twoPi : lNorm,
        latitude:  b,
        distance:  r,
        frame:     .ecliptic(equinox: jd, origin: .heliocentric)
    )
}

func heliocentricPosition(of body: SolarSystemBody, at time: AstroTime) -> SphericalPosition {
    heliocentricPosition(of: body, at: time.tt)
}

func heliocentricPosition(of body: SolarSystemBody, at date: Date) -> SphericalPosition {
    heliocentricPosition(of: body, at: AstroTime(date).tt)
}

// MARK: - VSOPEphemeris

/// VSOP87D-backed implementation of ``EphemerisProvider``.
///
/// Register once at startup so that ``SphericalPosition/converted(to:)`` can
/// perform heliocentric → geocentric reductions:
/// ```swift
/// SphericalPosition.ephemeris = VSOPEphemeris()
/// ```
public struct VSOPEphemeris: EphemerisProvider, Sendable {
    public init() {}

    public func earthHeliocentricEclipticPosition(at jd: JulianDay) -> SphericalPosition {
        heliocentricPosition(of: .earth, at: jd)
    }
}

// MARK: - VSOPPlanetProvider

/// VSOP87D-backed implementation of ``PlanetPositionProvider``.
///
/// Register alongside ``VSOPEphemeris`` at startup:
/// ```swift
/// SphericalPosition.ephemeris = VSOPEphemeris()
/// Planet.positionProvider    = VSOPPlanetProvider()
/// ```
public struct VSOPPlanetProvider: PlanetPositionProvider, Sendable {
    public init() {}

    public func position(of body: SolarSystemBody, at time: AstroTime) throws -> SphericalPosition {
        try heliocentricPosition(of: body, at: time.tt)
            .converted(to: .equatorial(.icrs))
    }

    public func sunPosition(at time: AstroTime) throws -> SphericalPosition {
        // The Sun has no VSOP series. Its geocentric vector = −Earth's heliocentric vector.
        let earth = heliocentricPosition(of: .earth, at: time.tt)
        let twoPi = 2.0 * Double.pi
        let lon = (earth.longitude + .pi).truncatingRemainder(dividingBy: twoPi)
        let geo = SphericalPosition(
            longitude: lon,
            latitude:  -earth.latitude,
            distance:  earth.distance,
            frame:     .ecliptic(equinox: time.tt)
        )
        return try geo.converted(to: .equatorial(.icrs))
    }
}

// MARK: - Internal series engine

/// A single VSOP87 term: contribution = a · cos(b + c · τ).
typealias VSOpTerm = (a: Double, b: Double, c: Double)

/// All L/B/R series for one body.  Each element of the outer array
/// is one power level (index 0 = τ⁰, index 1 = τ¹, …).
struct PlanetSeries {
    let l: [[VSOpTerm]]
    let b: [[VSOpTerm]]
    let r: [[VSOpTerm]]

    func evaluate(tau: Double) -> (l: Double, b: Double, r: Double) {
        (eval(l, tau), eval(b, tau), eval(r, tau))
    }

    private func eval(_ series: [[VSOpTerm]], _ tau: Double) -> Double {
        var result = 0.0
        var tauPow = 1.0
        for level in series {
            var sum = 0.0
            for (a, b, c) in level { sum += a * cos(b + c * tau) }
            result += sum * tauPow
            tauPow *= tau
        }
        return result / 1e8
    }
}

extension SolarSystemBody {
    var vsopSeries: PlanetSeries {
        switch self {
        case .mercury: return .mercury
        case .venus:   return .venus
        case .earth:   return .earth
        case .mars:    return .mars
        case .jupiter: return .jupiter
        case .saturn:  return .saturn
        case .uranus:  return .uranus
        case .neptune: return .neptune
        }
    }
}
