// MARK: - CoordinateOrigin

/// The physical origin of a position vector — where "zero distance" is.
///
/// All coordinate frames can in principle be centered at different points.
/// Tracking the origin alongside the frame prevents silently passing a
/// heliocentric position to a routine that expects geocentric coordinates.
///
/// - heliocentric  — centre of the Sun (VSOP87D output)
/// - geocentric    — centre of the Earth (standard for sky coordinates)
/// - barycentric   — Solar System Barycentre (e.g. DE-series outputs)
/// - topocentric   — surface observer (horizontal coordinates, or after
///                       diurnal-parallax correction)
public enum CoordinateOrigin: Sendable, Equatable {

    /// Centred on the Sun.  Typical for raw VSOP87D heliocentric output.
    case heliocentric

    /// Centred on the Earth's centre of mass.
    /// Standard origin for apparent sky positions.
    case geocentric

    /// Centred on the Solar System Barycentre.
    case barycentric

    /// Centred on a surface observer.
    /// All horizontal-frame positions carry this origin automatically;
    /// the observer's location is embedded in the CoordinateFrame.
    case topocentric(Observatory)
}

import Foundation

// MARK: - EquatorialFrame

/// Specific realization of the equatorial coordinate system.
///
/// Equatorial coordinates are all RA/Dec, but differ in which reference points
/// and which corrections have been applied:
///
/// - `icrs` — fixed, epoch-free, the standard for modern catalogues
/// - `fk5` — mean equator and equinox of a given Julian epoch (e.g. J2000.0)
/// - `cirs` — geocentric apparent, using the Celestial Intermediate Reference
///   System (modern replacement for "apparent of date"); output of the
///   ICRS → space-motion → aberration → precession/nutation pipeline
/// - `apparentOfDate` — classical apparent RA/Dec using the true equinox;
///   related to CIRS by subtracting the equation of the origins from RA
public enum EquatorialFrame: Sendable {

    /// International Celestial Reference System — fixed catalog frame, no epoch.
    /// Standard for Gaia, Hipparcos, and all modern catalogs.
    case icrs

    /// FK5 mean equatorial coordinates for a given Julian epoch.
    case fk5(equinox: JulianYear)

    /// Celestial Intermediate Reference System — geocentric apparent, of date.
    case cirs(jd: JulianDay)

    /// Classical apparent place — true equator and equinox of date.
    case apparentOfDate(jd: JulianDay)
}

/// The coordinate frame in which a `SphericalPosition` is expressed.
///
/// The physical origin of the position vector is embedded in the frame,
/// except for `.horizontal` which is always topocentric.
public enum CoordinateFrame: Sendable {

    /// Equatorial (RA / Dec) with a specific realization and physical origin.
    case equatorial(EquatorialFrame, CoordinateOrigin = .geocentric)

    /// Ecliptic longitude and latitude of date, with physical origin.
    case ecliptic(equinox: JulianDay, origin: CoordinateOrigin = .geocentric)

    /// Galactic longitude (l) and latitude (b), with physical origin.
    /// Fixed frame defined relative to ICRS; no epoch needed.
    case galactic(origin: CoordinateOrigin = .geocentric)

    /// Topocentric horizontal: azimuth (N through E) and elevation.
    /// Always topocentric — the observer is embedded in the frame.
    /// - Parameters:
    ///   - observer: Geographic location and atmospheric conditions.
    ///   - jd: Julian Date in UTC.
    ///   - refracted: `true` if atmospheric refraction is included.
    case horizontal(observer: Observatory, jd: JulianDay, refracted: Bool)
}

// MARK: - Origin helper

extension CoordinateFrame {

    /// The physical origin embedded in this frame.
    public var origin: CoordinateOrigin {
        switch self {
        case .equatorial(_, let o):          return o
        case .ecliptic(_, let o):            return o
        case .galactic(let o):               return o
        case .horizontal(let obs, _, _):     return .topocentric(obs)
        }
    }
}

// MARK: - AstroTime / Date convenience factories

public extension CoordinateFrame {

    /// Ecliptic frame of date from an ``AstroTime`` (uses TT internally).
    static func ecliptic(_ time: AstroTime) -> CoordinateFrame { .ecliptic(equinox: time.tt) }

    /// Ecliptic frame of date from a Swift `Date` (converted to TT).
    static func ecliptic(_ date: Date)      -> CoordinateFrame { .ecliptic(equinox: AstroTime(date).tt) }

    /// CIRS equatorial frame from an ``AstroTime`` (uses TT internally).
    static func cirs    (_ time: AstroTime) -> CoordinateFrame { .equatorial(.cirs(jd: time.tt)) }

    /// CIRS equatorial frame from a Swift `Date` (converted to TT).
    static func cirs    (_ date: Date)      -> CoordinateFrame { .equatorial(.cirs(jd: AstroTime(date).tt)) }
}
