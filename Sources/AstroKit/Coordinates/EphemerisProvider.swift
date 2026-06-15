// MARK: - EphemerisProvider

/// A backend that supplies solar system body positions for coordinate origin conversions.
///
/// Assign a concrete implementation to ``SphericalPosition/ephemeris`` once at startup:
/// ```swift
/// SphericalPosition.ephemeris = VSOPEphemeris()
/// ```
///
/// ``SphericalPosition/converted(to:)`` calls this when it needs to shift the
/// physical origin of a position — for example when converting a heliocentric VSOP87D
/// result to geocentric so it can be further transformed to equatorial or horizontal.
///
/// Different ephemeris packages (VSOP87D, SPICE, …) each provide their own
/// conforming type.  At most one provider should be active at a time.
public protocol EphemerisProvider: Sendable {

    /// Heliocentric ecliptic position of Earth (ecliptic and equinox of date)
    /// at the given TT Julian Day.
    ///
    /// The returned ``SphericalPosition`` must satisfy:
    /// - `frame == .ecliptic(equinox:, origin: .heliocentric)`
    /// - `distance` set to the Earth–Sun distance in AU.
    func earthHeliocentricEclipticPosition(at jd: JulianDay) -> SphericalPosition
}

// MARK: - Global provider slot

extension SphericalPosition {

    /// The active ephemeris backend used by ``converted(to:)`` for origin shifts.
    ///
    /// Set this once at application startup before any origin-changing conversions:
    /// ```swift
    /// SphericalPosition.ephemeris = VSOPEphemeris()
    /// ```
    nonisolated(unsafe) public static var ephemeris: (any EphemerisProvider)?
}
