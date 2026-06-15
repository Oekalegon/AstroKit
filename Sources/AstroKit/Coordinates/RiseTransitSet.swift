internal import CERFA
import Foundation

// MARK: - Standard altitude constants

public extension Double {
    /// Standard altitude for stars: −34′ (atmospheric refraction at horizon).
    static let standardAltitudeStar:  Double = -0.5817 * .pi / 180
    /// Standard altitude for the Sun: −50′ (refraction + semi-diameter).
    static let standardAltitudeSun:   Double = -0.8333 * .pi / 180
    /// Civil twilight: Sun centre at −6°.
    static let civilTwilight:         Double = -6.0    * .pi / 180
    /// Nautical twilight: Sun centre at −12°.
    static let nauticalTwilight:      Double = -12.0   * .pi / 180
    /// Astronomical twilight: Sun centre at −18°.
    static let astronomicalTwilight:  Double = -18.0   * .pi / 180
}

// MARK: - Window mode

/// Controls which time window is used for rise/transit/set calculations.
public enum RiseTransitSetWindow: Sendable {

    /// Midnight-to-midnight in the device's local time zone.
    ///
    /// The classic almanac view — today's sunrise appears before today's sunset.
    case day

    /// Noon-to-noon in the device's local time zone.
    ///
    /// The "tonight" view — this evening's sunset appears *before* tomorrow morning's
    /// sunrise, making it natural for planning an observing session.
    case night

    /// Only events strictly after the `date` passed to `riseTransitSet(on:at:...)`.
    ///
    /// All returned times are in the future. The search window extends 25 hours forward
    /// to cover the Moon's ~24h50m transit cycle.
    case next
}

// MARK: - Result types

/// Result of a rise/transit/set calculation for one time window.
public struct RiseTransitSet: Sendable {

    /// Time the body rises above `altitude`. `nil` if it never rises in the window.
    public let rise: Date?
    /// Time the body transits (highest point). `nil` if always below horizon.
    public let transit: Date?
    /// Time the body sets below `altitude`. `nil` if it never sets in the window.
    public let set: Date?
    /// `true` if the body is above `altitude` for the entire window.
    public let isAlwaysAbove: Bool
    /// `true` if the body is below `altitude` for the entire window.
    public let isAlwaysBelow: Bool

    /// Compute rise, transit, and set times within a given window.
    ///
    /// - Parameters:
    ///   - positionAt:  Returns the body's ICRS position at the given time.
    ///   - windowStart: Start of the search window.
    ///   - windowEnd:   End of the search window.
    ///   - observer:    Geographic location of the observer.
    ///   - altitude:    Target altitude in radians (default: standard star altitude −34′).
    ///   - cutoff:      When non-nil, only events strictly after this date are reported
    ///                  (used by `.next` mode).
    static func compute(
        of positionAt: (AstroTime) -> SphericalPosition,
        windowStart: Date,
        windowEnd: Date,
        at observer: Observatory,
        altitude: Double = .standardAltitudeStar,
        cutoff: Date? = nil
    ) -> RiseTransitSet {
        let allCrossings = ElevationCrossing.compute(of: positionAt,
                                                     windowStart: windowStart,
                                                     windowEnd: windowEnd,
                                                     at: observer, elevation: altitude)

        let sampleTime = AstroTime(windowStart + 300.0)
        let samplePos  = positionAt(sampleTime)
        let sampleAlt  = Algorithm.altitudeICRS(ra: samplePos.longitude, dec: samplePos.latitude,
                                                 observer: observer, at: sampleTime)
        let aboveAtSample = sampleAlt >= altitude

        let isAlwaysAbove = allCrossings.isEmpty &&  aboveAtSample
        let isAlwaysBelow = allCrossings.isEmpty && !aboveAtSample

        // For .next mode, filter crossings to those strictly after the cutoff.
        let crossings = cutoff.map { c in allCrossings.filter { $0.date > c } } ?? allCrossings
        let riseDate  = crossings.first(where: {  $0.isRising })?.date
        let setDate   = crossings.first(where: { !$0.isRising })?.date

        // Coarse scan: find the step with maximum altitude.
        let stepSeconds = 600.0
        let nSteps      = Int(windowEnd.timeIntervalSince(windowStart) / stepSeconds)
        var bestAlt     = -Double.pi / 2
        var bestTime: AstroTime?
        for i in 0..<nSteps {
            let t   = AstroTime(windowStart + Double(i) * stepSeconds)
            let pos = positionAt(t)
            let alt = Algorithm.altitudeICRS(ra: pos.longitude, dec: pos.latitude,
                                              observer: observer, at: t)
            if alt > bestAlt { bestAlt = alt; bestTime = t }
        }

        // Refine transit via iterated ternary search.
        var transitDate: Date?
        if let best = bestTime, !isAlwaysBelow {
            var estimate = best.date
            for _ in 0..<5 {
                let pos = positionAt(AstroTime(estimate))
                let refined = Algorithm.ternaryMaximum(
                    lo: estimate - stepSeconds, hi: estimate + stepSeconds,
                    f: { t in Algorithm.altitudeICRS(ra: pos.longitude, dec: pos.latitude,
                                                      observer: observer, at: AstroTime(t)) },
                    precision: 1.0
                )
                let converged = abs(refined.timeIntervalSince(estimate)) < 1.0
                estimate = refined
                if converged { break }
            }
            let transitPos = positionAt(AstroTime(estimate))
            let transitAlt = Algorithm.altitudeICRS(ra: transitPos.longitude,
                                                     dec: transitPos.latitude,
                                                     observer: observer, at: AstroTime(estimate))
            let afterCutoff = cutoff.map { estimate > $0 } ?? true
            if (transitAlt >= altitude || isAlwaysAbove)
                && estimate >= windowStart && estimate <= windowEnd
                && afterCutoff {
                transitDate = estimate
            }
        }

        return RiseTransitSet(rise: riseDate, transit: transitDate, set: setDate,
                               isAlwaysAbove: isAlwaysAbove, isAlwaysBelow: isAlwaysBelow)
    }
}

/// A single elevation crossing (body moving through a target altitude).
public struct ElevationCrossing: Sendable {

    /// The time of the crossing.
    public let date: Date
    /// `true` if the body is ascending through the altitude, `false` if descending.
    public let isRising: Bool

    /// Find all times within the given window when a body crosses a target elevation.
    ///
    /// - Parameters:
    ///   - positionAt:  Returns the body's ICRS position at the given time.
    ///   - windowStart: Start of the search window.
    ///   - windowEnd:   End of the search window.
    ///   - observer:    Geographic location of the observer.
    ///   - elevation:   Target elevation in radians.
    static func compute(
        of positionAt: (AstroTime) -> SphericalPosition,
        windowStart: Date,
        windowEnd: Date,
        at observer: Observatory,
        elevation: Double
    ) -> [ElevationCrossing] {
        let stepSec = 600.0
        let nSteps  = Int(windowEnd.timeIntervalSince(windowStart) / stepSec)

        var altitudes = [Double](repeating: 0, count: nSteps + 1)
        for i in 0...nSteps {
            let t = AstroTime(windowStart + Double(i) * stepSec)
            let pos = positionAt(t)
            altitudes[i] = Algorithm.altitudeICRS(ra: pos.longitude, dec: pos.latitude,
                                                   observer: observer, at: t)
        }

        var crossings: [ElevationCrossing] = []
        for i in 0..<nSteps {
            let a0 = altitudes[i]     - elevation
            let a1 = altitudes[i + 1] - elevation
            guard a0 * a1 < 0 else { continue }

            let t0 = windowStart + Double(i)     * stepSec
            let t1 = windowStart + Double(i + 1) * stepSec
            let midpoint = Date(timeIntervalSinceReferenceDate:
                                    (t0.timeIntervalSinceReferenceDate
                                     + t1.timeIntervalSinceReferenceDate) / 2)

            let crossingDate = Algorithm.iteratedCrossing(
                near: midpoint, between: t0, and: t1,
                positionAt: positionAt, observer: observer, elevation: elevation
            )
            crossings.append(ElevationCrossing(date: crossingDate, isRising: a1 > a0))
        }
        return crossings.sorted { $0.date < $1.date }
    }
}

// MARK: - Private algorithmic helpers

/// Namespace for all numerical algorithms used in rise/transit/set calculations.
private enum Algorithm {

    /// Altitude of a body in ICRS at the observer's location and time.
    static func altitudeICRS(ra: Double, dec: Double,
                              observer: Observatory, at time: AstroTime) -> Double {
        let ttJD  = time.tt
        let utcJD = time.converted(to: .utc).jd
        let gast  = eraGst06a(floor(utcJD.value), utcJD.value - floor(utcJD.value),
                               floor(ttJD.value),  ttJD.value  - floor(ttJD.value))
        let H      = gast + observer.longitude - ra
        let sinAlt = sin(observer.latitude) * sin(dec)
                   + cos(observer.latitude) * cos(dec) * cos(H)
        return asin(max(-1.0, min(1.0, sinAlt)))
    }

    /// Find the elevation crossing nearest to `initial` by iterating position updates.
    static func iteratedCrossing(
        near initial: Date,
        between lo: Date, and hi: Date,
        positionAt: (AstroTime) -> SphericalPosition,
        observer: Observatory,
        elevation: Double,
        tolerance: Double = 1.0
    ) -> Date {
        var estimate = initial
        for _ in 0..<6 {
            let pos = positionAt(AstroTime(estimate))
            let f: (Date) -> Double = { t in
                altitudeICRS(ra: pos.longitude, dec: pos.latitude,
                             observer: observer, at: AstroTime(t)) - elevation
            }
            guard f(lo) * f(hi) < 0 else { break }
            let refined  = bisect(t0: lo, t1: hi, f: f, precision: tolerance)
            let converged = abs(refined.timeIntervalSince(estimate)) < tolerance
            estimate = refined
            if converged { break }
        }
        return estimate
    }

    /// Bisection root-finding for `f` on `[t0, t1]` (opposite signs assumed).
    static func bisect(t0: Date, t1: Date, f: (Date) -> Double, precision: Double) -> Date {
        var lo = t0;  var hi = t1;  var fLo = f(lo);  var iter = 0
        while hi.timeIntervalSince(lo) > precision && iter < 60 {
            let mid  = Date(timeIntervalSinceReferenceDate:
                                (lo.timeIntervalSinceReferenceDate
                                 + hi.timeIntervalSinceReferenceDate) / 2)
            let fMid = f(mid)
            if fLo * fMid <= 0 { hi = mid } else { lo = mid; fLo = fMid }
            iter += 1
        }
        return Date(timeIntervalSinceReferenceDate:
                        (lo.timeIntervalSinceReferenceDate
                         + hi.timeIntervalSinceReferenceDate) / 2)
    }

    /// Ternary-search maximum of `f` on `[lo, hi]` to `precision` seconds.
    static func ternaryMaximum(lo: Date, hi: Date, f: (Date) -> Double,
                                precision: Double) -> Date {
        var a = lo;  var b = hi;  var iter = 0
        while b.timeIntervalSince(a) > precision && iter < 60 {
            let m1 = Date(timeIntervalSinceReferenceDate:
                              a.timeIntervalSinceReferenceDate + b.timeIntervalSince(a) / 3.0)
            let m2 = Date(timeIntervalSinceReferenceDate:
                              b.timeIntervalSinceReferenceDate - b.timeIntervalSince(a) / 3.0)
            if f(m1) < f(m2) { a = m1 } else { b = m2 }
            iter += 1
        }
        return Date(timeIntervalSinceReferenceDate:
                        (a.timeIntervalSinceReferenceDate
                         + b.timeIntervalSinceReferenceDate) / 2)
    }
}
