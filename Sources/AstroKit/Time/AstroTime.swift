internal import CERFA
import Foundation

// MARK: - TimeScale

/// The time scale in which a Julian Day number is expressed.
///
/// Astronomical algorithms use several closely related but distinct time scales:
///
/// | Scale | Relationship | Typical use |
/// |-------|-------------|-------------|
/// | TT    | TAI + 32.184 s (exact) | VSOP87, ERFA positional algorithms |
/// | TAI   | —           | Atomic clocks; stepping stone between TT and UTC |
/// | UTC   | TAI − (leap seconds) | Civil time; Swift `Date` |
/// | UT1   | UTC + ΔUT1 (|ΔUT1| < 0.9 s) | Earth rotation angle, sidereal time |
public enum TimeScale: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Terrestrial Time — used by VSOP87 and ERFA positional algorithms.
    case tt
    /// International Atomic Time; TT = TAI + 32.184 s (exact, always).
    case tai
    /// Coordinated Universal Time; has leap seconds; Swift `Date` uses this.
    case utc
    /// Universal Time; UT1 = UTC + ΔUT1 (|ΔUT1| < 0.9 s, IERS published).
    case ut1

    public var description: String {
        switch self {
        case .tt:  return "TT"
        case .tai: return "TAI"
        case .utc: return "UTC"
        case .ut1: return "UT1"
        }
    }
}

// MARK: - AstroTime

/// A moment in time expressed as a Julian Day number in a specific time scale.
///
/// ``AstroTime`` pairs a ``JulianDay`` value with its ``TimeScale``, eliminating
/// the common bug of passing a UTC Julian Day to an algorithm that expects TT.
///
/// ## Quick start
///
/// ```swift
/// // From a Swift Date (UTC):
/// let now = AstroTime(Date())
///
/// // Obtain a TT Julian Day for VSOP87 / ERFA:
/// let jdTT: JulianDay = now.tt
///
/// // From a known TT epoch:
/// let j2000 = AstroTime(.j2000, scale: .tt)
///
/// // Convert between scales:
/// let ut1Time = now.converted(to: .ut1)
/// ```
///
/// ## ΔUT1
///
/// `dut1` carries the IERS-published UT1 − UTC offset (seconds).  The default of
/// 0.0 introduces an error of at most 0.9 s (< 0.05 arcsec in Earth rotation),
/// which is negligible for most purposes.  Supply the current value from
/// <https://www.iers.org/IERS/EN/DataProducts/EarthOrientationData/eop.html>
/// when sub-arcsecond accuracy in sidereal / horizontal coordinates is required.
public struct AstroTime: Sendable, Equatable, Hashable, CustomStringConvertible {

    // MARK: Stored properties

    /// The Julian Day number in the stored ``scale``.
    public let jd: JulianDay

    /// The time scale of ``jd``.
    public let scale: TimeScale

    /// UT1 − UTC, in seconds.  Used when converting to or from `.ut1`.
    /// The IERS keeps |ΔUT1| < 0.9 s by inserting leap seconds into UTC.
    public let dut1: Double

    // MARK: Initialisers

    /// Create an ``AstroTime`` from a raw Julian Day in a known scale.
    ///
    /// - Parameters:
    ///   - jd:    Julian Day number in the given `scale`.
    ///   - scale: Time scale of `jd`.
    ///   - dut1:  UT1 − UTC offset in seconds (default 0.0).
    public init(_ jd: JulianDay, scale: TimeScale, dut1: Double = 0.0) {
        self.jd    = jd
        self.scale = scale
        self.dut1  = dut1
    }

    /// Create an ``AstroTime`` from a Swift `Date`.
    ///
    /// Swift's `Date` reference epoch is 2001-Jan-01 00:00:00 UTC, which
    /// corresponds to JD 2451910.5 (UTC scale).
    ///
    /// - Parameters:
    ///   - date: The moment to represent.
    ///   - dut1: UT1 − UTC offset in seconds (default 0.0).
    public init(_ date: Date = Date(), dut1: Double = 0.0) {
        // Swift Date reference epoch → JD 2451910.5 UTC
        let jdUTC = JulianDay(date.timeIntervalSinceReferenceDate / 86400.0 + 2451910.5)
        self.jd    = jdUTC
        self.scale = .utc
        self.dut1  = dut1
    }

    // MARK: Conversions

    /// This moment expressed as a TT Julian Day, ready for VSOP87 and ERFA functions.
    ///
    /// Conversion path:
    /// - `.tt`  → identity
    /// - `.tai` → `eraTaitt`
    /// - `.utc` → `eraUtctai` → `eraTaitt`
    /// - `.ut1` → `eraUt1utc` (using ``dut1``) → `eraUtctai` → `eraTaitt`
    public var tt: JulianDay {
        // Split JD into two parts for ERFA (high + low) to preserve precision.
        let (jd1, jd2) = twoPartJD(jd)

        switch scale {

        case .tt:
            return jd

        case .tai:
            var tt1 = 0.0, tt2 = 0.0
            _ = eraTaitt(jd1, jd2, &tt1, &tt2)
            return JulianDay(tt1 + tt2)

        case .utc:
            var tai1 = 0.0, tai2 = 0.0
            _ = eraUtctai(jd1, jd2, &tai1, &tai2)
            var tt1 = 0.0, tt2 = 0.0
            _ = eraTaitt(tai1, tai2, &tt1, &tt2)
            return JulianDay(tt1 + tt2)

        case .ut1:
            // UT1 → UTC → TAI → TT
            var utc1 = 0.0, utc2 = 0.0
            _ = eraUt1utc(jd1, jd2, dut1, &utc1, &utc2)
            var tai1 = 0.0, tai2 = 0.0
            _ = eraUtctai(utc1, utc2, &tai1, &tai2)
            var tt1 = 0.0, tt2 = 0.0
            _ = eraTaitt(tai1, tai2, &tt1, &tt2)
            return JulianDay(tt1 + tt2)
        }
    }

    /// This moment as a Swift `Date` (UTC).
    ///
    /// Conversion path: TT → TAI (`eraTttai`) → UTC (`eraTaiutc`).
    public var date: Date {
        // Go via TT → TAI → UTC
        let ttJD = tt
        let (tt1, tt2) = twoPartJD(ttJD)

        var tai1 = 0.0, tai2 = 0.0
        _ = eraTttai(tt1, tt2, &tai1, &tai2)

        var utc1 = 0.0, utc2 = 0.0
        _ = eraTaiutc(tai1, tai2, &utc1, &utc2)

        let utcJD = utc1 + utc2
        let ti = (utcJD - 2451910.5) * 86400.0
        return Date(timeIntervalSinceReferenceDate: ti)
    }

    /// Return a new ``AstroTime`` in the requested scale, pivoting through TT.
    ///
    /// - Parameter target: The desired ``TimeScale``.
    /// - Returns: An ``AstroTime`` whose ``jd`` is expressed in `target`.
    public func converted(to target: TimeScale) -> AstroTime {
        if target == scale { return self }

        // Pivot through TT, then convert TT → target.
        let ttJD = tt
        let (tt1, tt2) = twoPartJD(ttJD)

        switch target {

        case .tt:
            return AstroTime(ttJD, scale: .tt, dut1: dut1)

        case .tai:
            var tai1 = 0.0, tai2 = 0.0
            _ = eraTttai(tt1, tt2, &tai1, &tai2)
            return AstroTime(JulianDay(tai1 + tai2), scale: .tai, dut1: dut1)

        case .utc:
            var tai1 = 0.0, tai2 = 0.0
            _ = eraTttai(tt1, tt2, &tai1, &tai2)
            var utc1 = 0.0, utc2 = 0.0
            _ = eraTaiutc(tai1, tai2, &utc1, &utc2)
            return AstroTime(JulianDay(utc1 + utc2), scale: .utc, dut1: dut1)

        case .ut1:
            var tai1 = 0.0, tai2 = 0.0
            _ = eraTttai(tt1, tt2, &tai1, &tai2)
            var utc1 = 0.0, utc2 = 0.0
            _ = eraTaiutc(tai1, tai2, &utc1, &utc2)
            var ut11 = 0.0, ut12 = 0.0
            _ = eraUtcut1(utc1, utc2, dut1, &ut11, &ut12)
            return AstroTime(JulianDay(ut11 + ut12), scale: .ut1, dut1: dut1)
        }
    }

    // MARK: CustomStringConvertible

    public var description: String {
        "JD \(jd.value) \(scale)"
    }

    // MARK: Private helpers

    /// Split a Julian Day into a two-part representation that preserves
    /// sub-millisecond precision in ERFA's internal arithmetic.
    ///
    /// ERFA computes with two `Double` components (e.g. `jd1 = 2451545.0`,
    /// `jd2 = 0.0`) to maintain ~1 µs resolution even for large JD values.
    private func twoPartJD(_ jd: JulianDay) -> (Double, Double) {
        // Use integer day + fractional day to maximise precision.
        let whole = floor(jd.value)
        let frac  = jd.value - whole
        return (whole, frac)
    }
}

// MARK: - Date convenience

public extension Date {

    // MARK: Date → AstroTime / JulianDay

    /// This date as an ``AstroTime`` in the UTC time scale.
    public var astroTime: AstroTime { AstroTime(self) }

    /// This date as a Julian Day in the requested time scale.
    ///
    /// Defaults to `.tt` — the scale expected by VSOP87 and ERFA functions.
    /// Pass `.utc` to get the raw UTC Julian Day without any conversion.
    public func julianDay(_ scale: TimeScale = .tt) -> JulianDay {
        AstroTime(self).converted(to: scale).jd
    }

    // MARK: AstroTime / JulianDay → Date

    /// Creates a `Date` from an ``AstroTime`` (converts to UTC via ERFA).
    public init(_ time: AstroTime) { self = time.date }

    /// Creates a `Date` from a ``JulianDay`` in the given time scale.
    ///
    /// Defaults to `.tt` so that JD values taken from ephemeris tables round-trip
    /// correctly.  Pass `.utc` when the JD came from a UTC source.
    ///
    /// - Parameters:
    ///   - jd:    Julian Day number.
    ///   - scale: Time scale of `jd` (default `.tt`).
    public init(julianDay jd: JulianDay, scale: TimeScale = .tt) {
        self = AstroTime(jd, scale: scale).date
    }

    /// Returns sunrise, transit, and sunset times for this date and a given observer location.
    /// 
    /// Uses the `Sun` object and its `riseTransitSet` method internally.
    /// Convenience method for the common case of computing solar rise/transit/set.
    /// - Parameters:
    ///   - date: The calendar day (midnight-to-midnight UTC).   
    ///   - observer: Geographic location of the observer.
    public func sunRiseTransitSet(on date: Date, at observer: Observatory) -> RiseTransitSet {
        let sun = Sun()
        return sun.riseTransitSet(on: date, at: observer)
    }


    /// Returns moonrise, transit, and moonset times for this date and a given observer location.
    /// 
    /// Uses the `Moon` object and its `riseTransitSet` method internally.
    /// Convenience method for the common case of computing lunar rise/transit/set.
    /// - Parameters:
    ///   - date: The calendar day (midnight-to-midnight UTC).   
    ///   - observer: Geographic location of the observer.
    public func moonRiseTransitSet(on date: Date, at observer: Observatory) -> RiseTransitSet {
        let moon = Moon()
        return moon.riseTransitSet(on: date, at: observer)
    }
}
