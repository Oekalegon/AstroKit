internal import CERFA
import Foundation

// MARK: - Sidereal Time

/// Sidereal time at a given epoch and optional observer location.
///
/// ```swift
/// let st = SiderealTime(observatory: oslo, time: AstroTime())
/// let gmst = st.greenwichMean      // radians
/// let gast = st.greenwichApparent  // radians
/// let last = st.local              // radians
/// ```
public struct SiderealTime: Sendable {

    /// The observer's geographic location, used for local sidereal time.
    public let observatory: Observatory

    /// The epoch at which sidereal time is evaluated.
    public let time: AstroTime

    /// Creates a `SiderealTime` for a given observer and epoch.
    public init(observatory: Observatory, time: AstroTime = AstroTime()) {
        self.observatory = observatory
        self.time = time
    }

    /// Convenience initialiser using a Swift `Date`.
    public init(observatory: Observatory, date: Date) {
        self.init(observatory: observatory, time: AstroTime(date))
    }

    /// Convenience initialiser for GMST/GAST when no specific observer location is needed.
    public init(time: AstroTime) {
        self.init(observatory: Observatory(longitude: 0, latitude: 0), time: time)
    }

    // MARK: - Computed properties

    /// Greenwich Mean Sidereal Time (GMST) in radians [0, 2π).
    ///
    /// Uses the IAU 2006 precession model (`eraGmst06`).
    public var greenwichMean: Double {
        let ut1 = time.converted(to: .ut1)
        let tt  = time.tt
        return eraGmst06(ut1.jd.value, 0.0, tt.value, 0.0)
    }

    /// Greenwich Apparent Sidereal Time (GAST) in radians [0, 2π).
    ///
    /// Includes the equation of the equinoxes (nutation) via `eraGst06a`.
    public var greenwichApparent: Double {
        let ut1 = time.converted(to: .ut1)
        let tt  = time.tt
        return eraGst06a(ut1.jd.value, 0.0, tt.value, 0.0)
    }

    /// Local Apparent Sidereal Time (LAST) in radians [0, 2π).
    ///
    /// LAST = GAST + observer longitude (east positive).
    public var local: Double {
        let last  = greenwichApparent + observatory.longitude
        let twoPi = 2.0 * Double.pi
        return (last.truncatingRemainder(dividingBy: twoPi) + twoPi)
               .truncatingRemainder(dividingBy: twoPi)
    }
}
