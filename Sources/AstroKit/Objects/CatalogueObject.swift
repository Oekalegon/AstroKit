/// Proper motion of a star using the standard catalog convention (Gaia/Hipparcos).
public struct ProperMotion: Sendable {

    /// RA component μ_α* = μ_α cos δ, in mas/yr.
    /// This is the form stored in Gaia and Hipparcos catalogs.
    public var ra: Double

    /// Dec component μ_δ, in mas/yr.
    public var dec: Double

    public init(ra: Double, dec: Double) {
        self.ra = ra
        self.dec = dec
    }
}

/// A star or other point source as recorded in an astrometric catalogue.
///
/// Positions are assumed to be ICRS. The `epoch` records *when* those
/// coordinates were measured — stars move through space, so to compute
/// the current position you must apply proper motion from `epoch` to now.
///
/// Example epochs:
/// - Gaia DR3: 2016.0
/// - Hipparcos: 1991.25
/// - FK5 J2000 catalog: 2000.0
public final class CatalogueObject: CelestialObject, @unchecked Sendable {

    /// ICRS position at the catalogue epoch.
    public var catalogPosition: SphericalPosition

    /// Epoch of the catalogue coordinates (e.g. `2016.0` for Gaia DR3).
    public var catalogEpoch: JulianYear

    /// Proper motion, or `nil` if unavailable.
    public var properMotion: ProperMotion?

    /// Trigonometric parallax in mas, or `nil` if unavailable.
    public var parallax: Double?

    /// Radial velocity in km/s (positive = receding), or `nil` if unavailable.
    public var radialVelocity: Double?

    public init(
        position: SphericalPosition,
        epoch: JulianYear,
        properMotion: ProperMotion? = nil,
        parallax: Double? = nil,
        radialVelocity: Double? = nil
    ) {
        self.catalogPosition = position
        self.catalogEpoch = epoch
        self.properMotion = properMotion
        self.parallax = parallax
        self.radialVelocity = radialVelocity
    }

    public func position(
        at time: AstroTime?,
        frame: CoordinateFrame = .equatorial(.icrs)
    ) throws -> SphericalPosition {
        let t = try AstroTime.resolve(time, frame: frame)
        // Extract the observation JD from the frame when it carries one;
        // for epoch-free frames (ICRS, galactic) use the resolved time's TT JD.
        let observationJD: JulianDay
        switch frame {
        case .horizontal(_, let jd, _),
             .ecliptic(let jd, _),
             .equatorial(.cirs(let jd), _),
             .equatorial(.apparentOfDate(let jd), _):
            observationJD = jd
        default:
            observationJD = t.tt
        }
        return (try? toSphericalPosition(in: frame, at: observationJD)) ?? catalogPosition
    }
}
