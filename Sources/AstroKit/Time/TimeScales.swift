// MARK: - JulianDay

/// A Julian Day Number — a continuous count of days from the Julian Period epoch
/// (JD 0.0 = 12:00 UT, 1 January 4713 BC).  J2000.0 = JD 2451545.0.
///
/// Use like `TimeInterval`: arithmetic against a plain `Double` (days) works naturally.
///
/// ```swift
/// let now: JulianDay = 2460000.5
/// let tomorrow = now + 1.0
/// let elapsed: Double = tomorrow - now  // 1.0
/// ```
public struct JulianDay: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral,
                         CustomStringConvertible {

    /// The underlying day count.
    public var value: Double

    public init(_ value: Double) { self.value = value }
    public init(floatLiteral value: Double) { self.value = value }

    // MARK: Standard epochs

    /// J2000.0 — January 1.5, 2000 TT.
    public static let j2000: JulianDay = 2451545.0

    // MARK: Conversions

    /// This Julian Day expressed as a Julian year (J2000.0-based).
    public var julianYear: JulianYear {
        JulianYear((value - 2451545.0) / 365.25 + 2000.0)
    }

    /// This Julian Day expressed as a Besselian year.
    public var besselianYear: BesselianYear {
        BesselianYear((value - 2415020.31352) / 365.242198781 + 1900.0)
    }

    /// This Julian Day expressed as a Julian century from J2000.0 (T).
    public var julianCentury: JulianCentury {
        JulianCentury((value - 2451545.0) / 36525.0)
    }

    // MARK: Arithmetic

    public static func + (lhs: JulianDay, rhs: Double) -> JulianDay { JulianDay(lhs.value + rhs) }
    public static func - (lhs: JulianDay, rhs: Double) -> JulianDay { JulianDay(lhs.value - rhs) }
    /// Interval between two Julian Days, in days.
    public static func - (lhs: JulianDay, rhs: JulianDay) -> Double { lhs.value - rhs.value }

    public static func < (lhs: JulianDay, rhs: JulianDay) -> Bool { lhs.value < rhs.value }

    public var description: String { "JD \(value)" }
}

// MARK: - JulianYear

/// A Julian year epoch, such as J2000.0 or J2016.0.
/// 1 Julian year = 365.25 days exactly.
///
/// Used to label coordinate epochs and catalogue measurement dates.
public struct JulianYear: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral,
                          CustomStringConvertible {

    /// The underlying year value (e.g. 2000.0).
    public var value: Double

    public init(_ value: Double) { self.value = value }
    public init(floatLiteral value: Double) { self.value = value }

    // MARK: Standard epochs

    /// J2000.0 — the standard modern reference epoch.
    public static let j2000: JulianYear = 2000.0

    // MARK: Conversions

    /// This Julian year as a Julian Day Number.
    public var julianDay: JulianDay {
        JulianDay(2451545.0 + (value - 2000.0) * 365.25)
    }

    /// This Julian year as a Besselian year.
    public var besselianYear: BesselianYear { julianDay.besselianYear }

    public static func < (lhs: JulianYear, rhs: JulianYear) -> Bool { lhs.value < rhs.value }

    public var description: String { "J\(value)" }
}

// MARK: - BesselianYear

/// A Besselian year epoch, such as B1950.0.
/// 1 Besselian year ≈ 365.2422 days (one mean tropical year).
///
/// Used in older catalogs (FK4, SAO).  B1900.0 = JD 2415020.31352.
public struct BesselianYear: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral,
                             CustomStringConvertible {

    /// The underlying year value (e.g. 1950.0).
    public var value: Double

    public init(_ value: Double) { self.value = value }
    public init(floatLiteral value: Double) { self.value = value }

    // MARK: Standard epochs

    /// B1950.0 — the standard FK4 reference epoch.
    public static let b1950: BesselianYear = 1950.0
    /// B1900.0 — the Newcomb precession reference epoch.
    public static let b1900: BesselianYear = 1900.0

    // MARK: Conversions

    private static let b1900JD: Double       = 2415020.31352
    private static let tropicalYear: Double  = 365.242198781

    /// This Besselian year as a Julian Day Number.
    public var julianDay: JulianDay {
        JulianDay(BesselianYear.b1900JD + (value - 1900.0) * BesselianYear.tropicalYear)
    }

    /// This Besselian year as a Julian year.
    public var julianYear: JulianYear { julianDay.julianYear }

    public static func < (lhs: BesselianYear, rhs: BesselianYear) -> Bool { lhs.value < rhs.value }

    public var description: String { "B\(value)" }
}

// MARK: - JulianCentury

/// A Julian century from J2000.0: T = (JD − 2451545.0) / 36525.
///
/// Many precession and nutation formulae use T as their argument.
/// T = 0 at J2000.0, T = 1 at J2100.0.
public struct JulianCentury: Sendable, Hashable, Comparable, ExpressibleByFloatLiteral,
                             CustomStringConvertible {

    /// The underlying century value (T).
    public var value: Double

    public init(_ value: Double) { self.value = value }
    public init(floatLiteral value: Double) { self.value = value }

    // MARK: Conversions

    /// This Julian century as a Julian Day Number.
    public var julianDay: JulianDay {
        JulianDay(2451545.0 + value * 36525.0)
    }

    /// This Julian century as a Julian year.
    public var julianYear: JulianYear { julianDay.julianYear }

    public static func < (lhs: JulianCentury, rhs: JulianCentury) -> Bool { lhs.value < rhs.value }

    public var description: String { "T=\(value)" }
}
