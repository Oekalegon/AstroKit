import Foundation

// MARK: - AngularCoordinate

/// A point on the unit sphere in HEALPix angular convention.
///
/// HEALPix uses **colatitude** (`theta`) rather than the more familiar
/// astronomical latitude:
///
/// | Symbol  | Meaning                         | Range   |
/// |---------|---------------------------------|---------|
/// | `theta` | Colatitude from north pole      | [0, π]  |
/// | `phi`   | Longitude (eastward)            | [0, 2π) |
///
/// Both angles are in radians.  To convert from equatorial RA / Dec:
/// `theta = π/2 − dec`,  `phi = ra`.
///
/// ```swift
/// // North pole
/// let pole  = AngularCoordinate(theta: 0, phi: 0)
///
/// // From RA/Dec (both in radians):
/// let coord = AngularCoordinate(rightAscension: ra, declination: dec)
/// ```
public struct AngularCoordinate: Sendable, Equatable, Hashable,
                                  CustomStringConvertible {

    // MARK: Stored properties

    /// Colatitude in radians: 0 at the north pole, π at the south pole.
    public var theta: Double

    /// Longitude in radians: [0, 2π).
    public var phi: Double

    // MARK: Initialisers

    /// Create from colatitude and longitude (HEALPix native convention).
    public init(theta: Double, phi: Double) {
        self.theta = theta
        self.phi   = phi
    }

    /// Create from equatorial right ascension and declination (both radians).
    ///
    /// - Parameters:
    ///   - rightAscension: RA in radians, used as `phi`.
    ///   - declination: Dec in radians; converted to colatitude via `π/2 − dec`.
    public init(rightAscension: Double, declination: Double) {
        self.theta = .pi / 2 - declination
        self.phi   = rightAscension
    }

    // MARK: Derived quantities

    /// Declination (latitude from equator) in radians: `π/2 − theta`.
    public var declination: Double { .pi / 2 - theta }

    /// Right ascension alias for `phi`.
    public var rightAscension: Double { phi }

    // MARK: CustomStringConvertible

    public var description: String {
        String(format: "(θ=%.6f rad, φ=%.6f rad)", theta, phi)
    }
}
