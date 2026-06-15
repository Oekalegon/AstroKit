internal import CERFA
import Foundation

// MARK: - SolarSystemBody

/// The eight solar system planets, used as a key to identify a body.
public enum SolarSystemBody: String, CaseIterable, Sendable {
    case mercury = "Mercury"
    case venus   = "Venus"
    case earth   = "Earth"
    case mars    = "Mars"
    case jupiter = "Jupiter"
    case saturn  = "Saturn"
    case uranus  = "Uranus"
    case neptune = "Neptune"
}

// MARK: - PlanetPositionProvider

/// A backend that can compute planetary and solar positions.
///
/// The built-in fallback is ``ERFAPlanetProvider`` (Simon et al. 1994 via ERFA,
/// accuracy ~4–86 arcseconds). For higher precision register a VSOP87 backend:
/// ```swift
/// Planet.positionProvider = VSOPPlanetProvider()
/// ```
/// Any other ephemeris package (DE440, SPICE, …) can implement this protocol too.
public protocol PlanetPositionProvider: Sendable {
    /// Geocentric ICRS position of a solar system body at the given time.
    func position(of body: SolarSystemBody, at time: AstroTime) throws -> SphericalPosition
    /// Geocentric ICRS position of the Sun at the given time.
    func sunPosition(at time: AstroTime) throws -> SphericalPosition
}

// MARK: - ERFAPlanetProvider

/// Built-in fallback planetary ephemeris using ERFA functions.
///
/// - **Planets** — `eraPlan94` (Simon et al. 1994): heliocentric positions accurate
///   to ~4–86 arcseconds depending on the body.
/// - **Sun** — `eraEpv00` (VSOP87-based low-order series): Earth heliocentric
///   position negated, accurate to ~1 arcsecond.
///
/// This provider is registered automatically as ``Planet/positionProvider``.
/// Replace it with ``VSOP/VSOPPlanetProvider`` for sub-arcsecond accuracy:
/// ```swift
/// Planet.positionProvider = VSOPPlanetProvider()
/// ```
public struct ERFAPlanetProvider: PlanetPositionProvider, Sendable {

    public init() {}

    public func sunPosition(at time: AstroTime) throws -> SphericalPosition {
        let (d1, d2) = split(time.tt)
        let (ex, ey, ez) = earthHeliocentric(d1: d1, d2: d2)
        // Geocentric Sun = −Earth heliocentric
        return cartesianToICRS(x: -ex, y: -ey, z: -ez)
    }

    public func position(of body: SolarSystemBody, at time: AstroTime) throws -> SphericalPosition {
        guard let np = plan94Index(for: body) else {
            throw AstroKitError.unsupportedTransformation
        }
        let (d1, d2) = split(time.tt)

        var pv: ((Double, Double, Double), (Double, Double, Double)) = ((0, 0, 0), (0, 0, 0))
        withUnsafeMutablePointer(to: &pv.0) { ptr in
            _ = eraPlan94(d1, d2, np, ptr)
        }
        let (px, py, pz) = pv.0   // heliocentric, J2000 equatorial frame, AU

        // Convert heliocentric → geocentric by subtracting Earth's heliocentric position.
        let (ex, ey, ez) = earthHeliocentric(d1: d1, d2: d2)
        return cartesianToICRS(x: px - ex, y: py - ey, z: pz - ez)
    }

    // MARK: - Private helpers

    /// Split a Julian Day value at the whole-day boundary for ERFA numerical precision.
    private func split(_ jd: JulianDay) -> (Double, Double) {
        let whole = floor(jd.value)
        return (whole, jd.value - whole)
    }

    /// Heliocentric Earth position (AU) in J2000 equatorial frame via `eraEpv00`.
    private func earthHeliocentric(d1: Double, d2: Double) -> (Double, Double, Double) {
        var pvh: ((Double, Double, Double), (Double, Double, Double)) = ((0, 0, 0), (0, 0, 0))
        var pvb: ((Double, Double, Double), (Double, Double, Double)) = ((0, 0, 0), (0, 0, 0))
        withUnsafeMutablePointer(to: &pvh.0) { ph in
            withUnsafeMutablePointer(to: &pvb.0) { pb in
                _ = eraEpv00(d1, d2, ph, pb)
            }
        }
        return pvh.0
    }

    /// Convert geocentric Cartesian (AU, J2000 equatorial) to a geocentric ICRS SphericalPosition.
    private func cartesianToICRS(x: Double, y: Double, z: Double) -> SphericalPosition {
        let dist  = sqrt(x*x + y*y + z*z)
        let dec   = asin(max(-1.0, min(1.0, z / dist)))
        let ra    = atan2(y, x)
        return SphericalPosition(longitude: ra < 0 ? ra + 2 * .pi : ra,
                                  latitude: dec, distance: dist,
                                  frame: .equatorial(.icrs))
    }

    /// Map `SolarSystemBody` to the `eraPlan94` body index (1–8).
    /// Returns `nil` for Earth (use `eraEpv00` instead).
    private func plan94Index(for body: SolarSystemBody) -> Int32? {
        switch body {
        case .mercury: return 1
        case .venus:   return 2
        case .mars:    return 4
        case .jupiter: return 5
        case .saturn:  return 6
        case .uranus:  return 7
        case .neptune: return 8
        case .earth:   return nil   // not a meaningful geocentric target
        }
    }
}

// MARK: - Planet

/// A solar system planet as a `CelestialObject`.
///
/// Delegates to the registered ``PlanetPositionProvider``.
/// The default provider is ``ERFAPlanetProvider`` (~4–86 arcsecond accuracy).
/// Replace it with a higher-precision backend at startup:
/// ```swift
/// Planet.positionProvider = VSOPPlanetProvider()   // sub-arcsecond accuracy
/// let jupiter = Planet(.jupiter)
/// ```
public struct Planet: CelestialObject, Sendable {

    /// The registered ephemeris backend.
    /// Defaults to ``ERFAPlanetProvider``; replace with `VSOPPlanetProvider` or another
    /// implementation for higher precision.
    nonisolated(unsafe) public static var positionProvider: any PlanetPositionProvider = ERFAPlanetProvider()

    /// The solar system body this planet represents.
    public let body: SolarSystemBody

    public init(_ body: SolarSystemBody) {
        self.body = body
    }

    public func position(
        at time: AstroTime?,
        frame: CoordinateFrame = .equatorial(.icrs)
    ) throws -> SphericalPosition {
        let t   = try AstroTime.resolve(time, frame: frame)
        let pos = try Planet.positionProvider.position(of: body, at: t)
        return (try? pos.converted(to: frame)) ?? pos
    }
}

// MARK: - Sun

/// The Sun as a `CelestialObject`.
///
/// Delegates to the registered ``Planet/positionProvider``:
/// ```swift
/// Planet.positionProvider = VSOPPlanetProvider()
/// let alt = try Sun().position(frame: .horizontal(observer: obs, jd: now, refracted: true))
/// ```
public struct Sun: CelestialObject, Sendable {

    public init() {}

    public func position(
        at time: AstroTime?,
        frame: CoordinateFrame = .equatorial(.icrs)
    ) throws -> SphericalPosition {
        let t   = try AstroTime.resolve(time, frame: frame)
        let pos = try Planet.positionProvider.sunPosition(at: t)
        return (try? pos.converted(to: frame)) ?? pos
    }
}

// MARK: - Moon

/// The Moon as a `CelestialObject`.
///
/// Uses ERFA's `eraMoon98` algorithm (an abridged version of the Meeus 1998 series)
/// to compute the geocentric position in the mean equatorial J2000 frame (≈ ICRS).
/// Accuracy is approximately 1 arcminute — suitable for rise/set, phase angle,
/// and casual sky-simulation purposes.
///
/// No registration is required; the algorithm is built into AstroKit via CERFA:
/// ```swift
/// let moon = Moon()
/// let pos  = try moon.position(at: AstroTime(), frame: .equatorial(.icrs))
/// let rts  = moon.riseTransitSet(on: Date(), at: oslo)
/// ```
public struct Moon: CelestialObject, Sendable {

    public init() {}

    public func position(
        at time: AstroTime?,
        frame: CoordinateFrame = .equatorial(.icrs)
    ) throws -> SphericalPosition {
        let t    = try AstroTime.resolve(time, frame: frame)
        let ttJD = t.tt

        // Split TT Julian Date at the whole-day boundary for ERFA numerical precision.
        let ttWhole = floor(ttJD.value)
        let ttFrac  = ttJD.value - ttWhole

        // eraMoon98 output: pv[0] = geocentric position (AU), pv[1] = velocity (AU/day).
        // The C type `double pv[2][3]` is imported by Swift as
        //   UnsafeMutablePointer<(Double, Double, Double)>
        // so we use a contiguous outer tuple and pass a pointer to its first element.
        var pv: ((Double, Double, Double), (Double, Double, Double)) = ((0, 0, 0), (0, 0, 0))
        withUnsafeMutablePointer(to: &pv.0) { ptr in
            eraMoon98(ttWhole, ttFrac, ptr)
        }

        let (x, y, z) = pv.0
        let dist  = sqrt(x*x + y*y + z*z)
        let dec   = asin(max(-1.0, min(1.0, z / dist)))
        let ra    = atan2(y, x)
        let raNorm = ra < 0 ? ra + 2 * .pi : ra

        let icrs = SphericalPosition(longitude: raNorm, latitude: dec, distance: dist,
                                      frame: .equatorial(.icrs))
        return (try? icrs.converted(to: frame)) ?? icrs
    }
}
