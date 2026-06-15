import Foundation

// MARK: - CelestialObject protocol

/// A body whose sky position can be computed at any given time.
public protocol CelestialObject: Sendable {

    /// Returns the position of this body at the given time in the requested frame.
    ///
    /// - Parameters:
    ///   - time:  Observation time.  When `nil`, time is inferred from the
    ///            ``CoordinateFrame/horizontal(observer:jd:refracted:)`` frame's
    ///            embedded Julian Day.  Passing `nil` with a non-horizontal frame
    ///            is equivalent to passing `AstroTime()` (current time).
    ///   - frame: Target coordinate frame.  The physical origin is embedded in
    ///            the frame (see ``CoordinateFrame/origin``).
    ///
    /// - Throws: ``AstroKitError/conflictingTimes`` if an explicit `time` is
    ///           supplied together with a `.horizontal` frame whose JD encodes a
    ///           different epoch (difference > 1 s).
    func position(
        at time: AstroTime?,
        frame: CoordinateFrame
    ) throws -> SphericalPosition
}

// MARK: - Default parameters

public extension CelestialObject {

    /// Convenience overload with default `time = nil` and `frame = .equatorial(.icrs)`.
    func position(
        at time: AstroTime? = nil,
        frame: CoordinateFrame = .equatorial(.icrs)
    ) throws -> SphericalPosition {
        try position(at: time, frame: frame)
    }

}

// MARK: - Shared helper

extension AstroTime {

    /// Resolve the effective observation time from an optional `AstroTime` and a `CoordinateFrame`.
    ///
    /// - If `time` is non-nil and frame is horizontal: validates agreement (throws on mismatch).
    /// - If `time` is non-nil and frame is not horizontal: returns `time`.
    /// - If `time` is nil and frame is horizontal: returns `AstroTime` from the frame's JD.
    /// - If `time` is nil and frame is not horizontal: returns `AstroTime()` (current time).
    ///
    /// Horizontal JD and explicit time are considered equal when they differ by less than 1 second.
    static func resolve(_ time: AstroTime?, frame: CoordinateFrame) throws -> AstroTime {
        switch frame {
        case .horizontal(_, let jd, _):
            if let t = time {
                // Both the supplied time and the horizontal-frame JD are compared in UTC.
                let tUTC = t.converted(to: .utc).jd.value
                let delta = abs(tUTC - jd.value) * 86400.0  // difference in seconds
                if delta > 1.0 { throw AstroKitError.conflictingTimes }
                return t
            } else {
                return AstroTime(jd, scale: .utc)
            }
        default:
            return time ?? AstroTime()
        }
    }
}

// MARK: - Elongation and illumination

public extension CelestialObject {

    /// Angular separation between this body and the Sun at the given time, in radians [0, π].
    ///
    /// - 0 rad  = conjunction (body and Sun in the same direction)
    /// - π/2 rad = quadrature
    /// - π rad  = opposition
    func elongation(at time: AstroTime = AstroTime()) throws -> Double {
        let bodyPos = try position(at: time)
        let sunPos  = try Sun().position(at: time)
        return SphericalPosition.angularSeparation(bodyPos, sunPos)
    }

    /// The fraction of this body's disk that is illuminated by the Sun [0, 1].
    ///
    /// Computed from the phase angle α at the body using `(1 + cos α) / 2`:
    /// - 1.0 = fully illuminated (full Moon / superior conjunction)
    /// - 0.5 = half illuminated (quadrature)
    /// - 0.0 = unilluminated (new Moon / inferior conjunction)
    ///
    /// Returns `nil` when the geocentric distance of the body or the Sun is not available
    /// (e.g. catalogue stars at unknown distance).
    func illuminatedFraction(at time: AstroTime = AstroTime()) throws -> Double? {
        let bodyPos = try position(at: time)
        let sunPos  = try Sun().position(at: time)

        guard let dp = bodyPos.distance, dp > 0,
              let ds = sunPos.distance,  ds > 0 else { return nil }

        // Geocentric Cartesian positions (AU, ICRS).
        let (px, py, pz) = bodyPos.cartesian
        let (sx, sy, sz) = sunPos.cartesian

        // Vector from body to Earth (geocentric origin) and from body to Sun.
        let bsDist = sqrt(pow(sx - px, 2) + pow(sy - py, 2) + pow(sz - pz, 2))
        guard bsDist > 0 else { return 1.0 }

        // Phase angle α: angle at the body subtended by Earth and Sun.
        let cosAlpha = ((-px) * (sx - px) + (-py) * (sy - py) + (-pz) * (sz - pz))
                     / (dp * bsDist)
        return (1.0 + cos(acos(max(-1.0, min(1.0, cosAlpha)))) ) / 2.0
    }
}

// MARK: - Rise / transit / set

public extension CelestialObject {

    /// Rise, transit, and set times for this body in the given time window.
    ///
    /// - Parameters:
    ///   - date:     Reference date. For `.day`/`.night` this anchors the window;
    ///               for `.next` this is the "not before" cutoff (default: now).
    ///   - observer: Geographic location of the observer.
    ///   - window:   Which time window to use (default: `.day()` — local midnight to midnight).
    ///   - altitude: Target altitude in radians (default: standard star altitude −34′).
    func riseTransitSet(
        on date: Date = Date(),
        at observer: Observatory,
        window: RiseTransitSetWindow = .day,
        altitude: Double = .standardAltitudeStar
    ) -> RiseTransitSet {
        let (windowStart, windowEnd) = WindowHelper.bounds(for: date, mode: window)
        let cutoff = WindowHelper.cutoff(for: date, mode: window)
        let fallback = SphericalPosition(longitude: 0, latitude: 0, frame: .equatorial(.icrs))
        return RiseTransitSet.compute(
            of: { [self] t in (try? self.position(at: t)) ?? fallback },
            windowStart: windowStart, windowEnd: windowEnd,
            at: observer, altitude: altitude, cutoff: cutoff
        )
    }

    /// Times when this body's elevation crosses a given threshold within the time window.
    ///
    /// - Parameters:
    ///   - date:      Reference date (see `riseTransitSet` for `.next` semantics).
    ///   - observer:  Geographic location of the observer.
    ///   - elevation: Target elevation in radians.
    ///   - window:    Which time window to use (default: `.day()` — local midnight to midnight).
    func elevationCrossings(
        on date: Date = Date(),
        at observer: Observatory,
        above elevation: Double,
        window: RiseTransitSetWindow = .day
    ) -> [ElevationCrossing] {
        let (windowStart, windowEnd) = WindowHelper.bounds(for: date, mode: window)
        let cutoff = WindowHelper.cutoff(for: date, mode: window)
        let fallback = SphericalPosition(longitude: 0, latitude: 0, frame: .equatorial(.icrs))
        var crossings = ElevationCrossing.compute(
            of: { [self] t in (try? self.position(at: t)) ?? fallback },
            windowStart: windowStart, windowEnd: windowEnd,
            at: observer, elevation: elevation
        )
        if let cutoff {
            crossings = crossings.filter { $0.date > cutoff }
        }
        return crossings
    }
}

// MARK: - Private window helper

private enum WindowHelper {

    /// Returns (windowStart, windowEnd) for the given mode and reference date.
    static func bounds(for date: Date, mode: RiseTransitSetWindow) -> (Date, Date) {
        switch mode {
        case .day:
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
            let start = cal.startOfDay(for: date)
            return (start, start + 86400)

        case .night:
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
            // Noon in local time — use DateComponents to handle DST correctly.
            var comps = cal.dateComponents([.year, .month, .day], from: date)
            comps.hour = 12; comps.minute = 0; comps.second = 0
            let noon = cal.date(from: comps) ?? cal.startOfDay(for: date) + 43200
            return (noon, noon + 86400)

        case .next:
            // 25 hours covers the Moon's ~24h50m transit cycle.
            return (date, date + 90000)
        }
    }

    /// Returns the cutoff date for `.next` mode, nil otherwise.
    static func cutoff(for date: Date, mode: RiseTransitSetWindow) -> Date? {
        if case .next = mode { return date }
        return nil
    }
}
