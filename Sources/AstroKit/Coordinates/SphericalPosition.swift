import Foundation

/// A position on the celestial sphere expressed as angular coordinates
/// in a specific coordinate frame.
///
/// The meaning of `longitude` and `latitude` depends on the frame:
///
/// | Frame       | longitude        | latitude         |
/// |-------------|------------------|------------------|
/// | equatorial  | RA (radians)     | Dec (radians)    |
/// | ecliptic    | ecliptic λ       | ecliptic β       |
/// | galactic    | l                | b                |
/// | horizontal  | azimuth (N→E)    | elevation        |
///
/// All angles are in radians.
///
/// The physical origin of the position vector is encoded in the frame —
/// e.g. `.ecliptic(equinox:, origin: .heliocentric)` for raw VSOP87D output
/// and `.equatorial(.icrs)` (default `.geocentric`) for catalogue objects.
public struct SphericalPosition: Sendable {

    /// Longitude-like angle in radians (RA, ecliptic lon, galactic l, azimuth).
    public var longitude: Double

    /// Latitude-like angle in radians (Dec, ecliptic lat, galactic b, elevation).
    public var latitude: Double

    /// Distance in AU, or `nil` if not known.
    public var distance: Double?

    /// The coordinate frame this position is expressed in.
    /// The physical origin is embedded in the frame (see ``CoordinateFrame/origin``).
    public var frame: CoordinateFrame

    /// The physical origin of this position vector, derived from the frame.
    ///
    /// - `.geocentric` for apparent sky positions and catalogue objects.
    /// - `.heliocentric` for raw VSOP87D output (use `.ecliptic(equinox:, origin: .heliocentric)`).
    /// - `.topocentric` is set automatically when converting to `.horizontal`.
    /// - `.barycentric` for positions referenced to the SSB.
    public var origin: CoordinateOrigin { frame.origin }

    public init(
        longitude: Double,
        latitude: Double,
        distance: Double? = nil,
        frame: CoordinateFrame
    ) {
        self.longitude = longitude
        self.latitude = latitude
        self.distance = distance
        self.frame = frame
    }

    /// Geocentric Cartesian coordinates (x, y, z) in AU.
    ///
    /// Returns `(0, 0, 0)` when `distance` is nil.
    var cartesian: (Double, Double, Double) {
        let d = distance ?? 0
        return (d * cos(latitude) * cos(longitude),
                d * cos(latitude) * sin(longitude),
                d * sin(latitude))
    }
}

// MARK: - Angular separation

public extension SphericalPosition {

    /// Great-circle angular separation between two positions, in radians.
    ///
    /// Uses the Vincenty formula, which is numerically stable for all angular scales
    /// from sub-arcsecond to 180°.
    ///
    /// - Parameters:
    ///   - a: First position.
    ///   - b: Second position.
    ///   - refracted: When `true` and both positions are in a `.horizontal` frame,
    ///     applies the Saemundsson (1986) atmospheric refraction correction to each
    ///     body's altitude before computing the separation. Has no effect for
    ///     non-horizontal frames.
    public static func angularSeparation(_ a: SphericalPosition, _ b: SphericalPosition,
                                   refracted: Bool = false) -> Double {
        let (lon1, lat1) = refracted ? apparentCoords(a) : (a.longitude, a.latitude)
        let (lon2, lat2) = refracted ? apparentCoords(b) : (b.longitude, b.latitude)
        let dLon = lon2 - lon1
        let c = sqrt(pow(cos(lat2) * sin(dLon), 2) +
                     pow(cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon), 2))
        let s = sin(lat1) * sin(lat2) + cos(lat1) * cos(lat2) * cos(dLon)
        return atan2(c, s)
    }

    /// Atmospheric refraction correction (Saemundsson 1986) in radians for a given altitude in radians.
    ///
    /// Returns 0 for altitudes below −1° (body is below the horizon).
    static func refractionCorrection(altitude: Double) -> Double {
        let altDeg = altitude * 180.0 / .pi
        guard altDeg > -1.0 else { return 0.0 }
        // Saemundsson formula: R in arcminutes → convert to radians
        let R = 1.02 / tan((altDeg + 10.3 / (altDeg + 5.11)) * .pi / 180.0)
        return R * .pi / (180.0 * 60.0)
    }

    // Apply refraction to a position's altitude when the frame is horizontal.
    private static func apparentCoords(_ pos: SphericalPosition) -> (Double, Double) {
        guard case .horizontal = pos.frame else { return (pos.longitude, pos.latitude) }
        return (pos.longitude, pos.latitude + refractionCorrection(altitude: pos.latitude))
    }
}
