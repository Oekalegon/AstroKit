internal import CERFA

// MARK: - Error

/// Errors that can occur during coordinate transformations.
public enum AstroKitError: Error, Sendable, Equatable {

    /// The requested source → target transformation is not supported.
    case unsupportedTransformation

    /// An ERFA function returned a negative (fatal) status code.
    case erfaError(Int32)

    /// ``SphericalPosition/converted(to:)`` needs to change the position origin
    /// but no ``EphemerisProvider`` has been registered.
    /// Set `SphericalPosition.ephemeris` before calling this method.
    case noEphemerisProvider

    /// An explicit observation time was supplied alongside a `.horizontal` frame
    /// that embeds a different Julian Day.  The two times must agree.
    case conflictingTimes
}

// MARK: - Internal unit helpers

private enum TransformHelper {

    /// 1 mas in radians.
    static let masToRad: Double = ERFA_DAS2R / 1000.0

    /// Standard atmosphere pressure estimate from height above sea level (metres).
    static func standardPressure(height: Double) -> Double {
        1013.25 * exp(-height / 8500.0)
    }

    /// Parallax in arcseconds → distance in AU. Returns `nil` for zero or negative parallax.
    static func parallaxArcSecToAU(_ arcsec: Double) -> Double? {
        arcsec > 0 ? 1.0 / (arcsec * ERFA_DAS2R) : nil
    }

    /// Convert `ProperMotion` (Gaia convention, mas/yr) to ERFA-expected units (rad/yr).
    ///
    /// ERFA uses dRA/dt (actual RA rate), while catalogs store μ_α* = μ_α cos δ.
    static func erfaProperMotion(pm: ProperMotion?, dec: Double) -> (pr: Double, pd: Double) {
        guard let pm else { return (0.0, 0.0) }
        let cosLat = cos(dec)
        let pr = cosLat > 1e-10 ? (pm.ra / cosLat) * masToRad : 0.0
        let pd = pm.dec * masToRad
        return (pr, pd)
    }

    /// Propagate an ICRS position from one Julian epoch to another using ERFA `eraStarpm`.
    /// Returns (ra, dec, parallax_arcsec) at the target epoch.
    /// Falls back to the source values if there is no motion or `eraStarpm` fails.
    static func propagateToEpoch(
        rc: Double, dc: Double, pr: Double, pd: Double, px: Double, rv: Double,
        from source: JulianDay, to target: JulianDay
    ) -> (ra: Double, dec: Double, px: Double) {
        guard target != source, (pr != 0 || pd != 0 || px > 0 || rv != 0) else {
            return (rc, dc, px)
        }
        var ra2 = 0.0, dec2 = 0.0, pmr2 = 0.0, pmd2 = 0.0, px2 = 0.0, rv2 = 0.0
        let status = eraStarpm(rc, dc, pr, pd, px, rv,
                               source.value, 0.0, target.value, 0.0,
                               &ra2, &dec2, &pmr2, &pmd2, &px2, &rv2)
        guard status >= 0 else { return (rc, dc, px) }
        return (ra2, dec2, px2)
    }

    static func effectivePressure(observer: Observatory, refracted: Bool) -> Double {
        guard refracted else { return 0.0 }
        return observer.pressure ?? standardPressure(height: observer.height)
    }
}

// MARK: - SphericalPosition transforms

extension SphericalPosition {

    /// Convert this position to a different coordinate frame, shifting the physical
    /// origin if necessary.
    ///
    /// The physical origin of the target position is embedded in `target`
    /// (e.g. `.ecliptic(equinox: jd, origin: .geocentric)`).
    /// If the target origin differs from `self.origin`, an origin shift is performed
    /// first using the registered ``ephemeris`` backend.
    ///
    /// ## Supported frame conversions
    ///
    /// | Source              | Target                                                  |
    /// |---------------------|---------------------------------------------------------|
    /// | ICRS                | CIRS, apparent of date, galactic, ecliptic, horizontal  |
    /// | CIRS                | ICRS, horizontal                                        |
    /// | Galactic            | ICRS                                                    |
    /// | Ecliptic            | ICRS                                                    |
    ///
    /// All other combinations throw ``AstroKitError/unsupportedTransformation``.
    ///
    /// > Note: Proper motion and parallax are **not** applied here; this converts a
    /// > bare angular position. For catalogue entries with kinematics use
    /// > ``CatalogueObject/toSphericalPosition(in:at:)``.
    public func converted(to target: CoordinateFrame) throws -> SphericalPosition {
        // Step 1 — shift origin if needed.
        let sameOrigin: SphericalPosition
        if self.origin == target.origin {
            sameOrigin = self
        } else {
            sameOrigin = try shiftOrigin(to: target.origin)
        }

        // Step 2 — rotate frame axes.
        return try sameOrigin.convertFrame(to: target)
    }

    // MARK: Private: frame-only rotation (origin must already match target)

    private func convertFrame(to target: CoordinateFrame) throws -> SphericalPosition {

        // Fast direct path: CIRS → Horizontal (no ICRS pivot needed)
        if case .equatorial(.cirs(_), _) = frame,
           case .horizontal(let observer, let jd, let refracted) = target {
            return try SphericalPosition.cirsToHorizontal(
                ra: longitude, dec: latitude,
                observer: observer, jd: jd, refracted: refracted
            )
        }

        // All other paths normalise to ICRS first, then convert to target.
        let (icrsRA, icrsDec) = try toICRS()
        return try SphericalPosition.fromICRS(
            ra: icrsRA, dec: icrsDec, distance: distance, to: target
        )
    }

    // MARK: Private: normalise to ICRS

    private func toICRS() throws -> (ra: Double, dec: Double) {
        switch frame {

        case .equatorial(.icrs, _):
            return (longitude, latitude)

        case .equatorial(.cirs(let jd), _):
            var ra: Double = 0, dec: Double = 0, eo: Double = 0
            eraAtic13(longitude, latitude, jd.value, 0.0, &ra, &dec, &eo)
            return (ra, dec)

        case .galactic(_):
            var ra: Double = 0, dec: Double = 0
            eraG2icrs(longitude, latitude, &ra, &dec)
            return (ra, dec)

        case .ecliptic(let jd, _):
            var ra: Double = 0, dec: Double = 0
            eraEceq06(jd.value, 0.0, longitude, latitude, &ra, &dec)
            return (ra, dec)

        default:
            throw AstroKitError.unsupportedTransformation
        }
    }

    // MARK: Private: ICRS → target frame

    private static func fromICRS(
        ra: Double, dec: Double, distance: Double?,
        to target: CoordinateFrame
    ) throws -> SphericalPosition {

        switch target {

        case .equatorial(.icrs, _):
            return SphericalPosition(longitude: ra, latitude: dec,
                                     distance: distance, frame: target)

        case .equatorial(.cirs(let jd), _):
            var ri: Double = 0, di: Double = 0, eo: Double = 0
            eraAtci13(ra, dec, 0, 0, 0, 0, jd.value, 0.0, &ri, &di, &eo)
            return SphericalPosition(longitude: ri, latitude: di,
                                     distance: distance, frame: target)

        case .equatorial(.apparentOfDate(let jd), _):
            var ri: Double = 0, di: Double = 0, eo: Double = 0
            eraAtci13(ra, dec, 0, 0, 0, 0, jd.value, 0.0, &ri, &di, &eo)
            let raApp = eraAnp(ri - eo)
            return SphericalPosition(longitude: raApp, latitude: di,
                                     distance: distance, frame: target)

        case .galactic(_):
            var l: Double = 0, b: Double = 0
            eraIcrs2g(ra, dec, &l, &b)
            return SphericalPosition(longitude: l, latitude: b,
                                     distance: distance, frame: target)

        case .ecliptic(let jd, _):
            var l: Double = 0, b: Double = 0
            eraEqec06(jd.value, 0.0, ra, dec, &l, &b)
            return SphericalPosition(longitude: l, latitude: b,
                                     distance: distance, frame: target)

        case .horizontal(let observer, let jd, let refracted):
            return try icrsToHorizontal(ra: ra, dec: dec, distance: distance,
                                        observer: observer, jd: jd, refracted: refracted)

        case .equatorial(.fk5, _):
            throw AstroKitError.unsupportedTransformation
        }
    }

    // MARK: Private: ERFA terminal transforms

    private static func icrsToHorizontal(
        ra: Double, dec: Double, distance: Double?,
        observer: Observatory, jd: JulianDay, refracted: Bool
    ) throws -> SphericalPosition {
        var aob: Double = 0, zob: Double = 0, hob: Double = 0
        var dob: Double = 0, rob: Double = 0, eo:  Double = 0

        let phpa = TransformHelper.effectivePressure(observer: observer, refracted: refracted)

        let status = eraAtco13(
            ra, dec,
            0.0, 0.0, 0.0, 0.0,           // pr, pd, px, rv — zero for bare position
            jd.value, 0.0,                  // UTC as two-part JD
            0.0,                            // ΔUT1 — negligible for most purposes
            observer.longitude,
            observer.latitude,
            observer.height,
            0.0, 0.0,                       // polar motion xp, yp
            phpa,
            observer.temperature,
            observer.humidity,
            0.55,                           // visual wavelength (μm)
            &aob, &zob, &hob, &dob, &rob, &eo
        )
        guard status >= 0 else { throw AstroKitError.erfaError(status) }

        let actuallyRefracted = refracted && phpa > 0
        return SphericalPosition(
            longitude: aob,
            latitude: .pi / 2.0 - zob,
            distance: distance,
            frame: .horizontal(observer: observer, jd: jd, refracted: actuallyRefracted)
        )
    }

    private static func cirsToHorizontal(
        ra: Double, dec: Double,
        observer: Observatory, jd: JulianDay, refracted: Bool
    ) throws -> SphericalPosition {
        var aob: Double = 0, zob: Double = 0, hob: Double = 0
        var dob: Double = 0, rob: Double = 0

        let phpa = TransformHelper.effectivePressure(observer: observer, refracted: refracted)

        let status = eraAtio13(
            ra, dec,
            jd.value, 0.0,                  // UTC as two-part JD
            0.0,                            // ΔUT1
            observer.longitude,
            observer.latitude,
            observer.height,
            0.0, 0.0,                       // polar motion xp, yp
            phpa,
            observer.temperature,
            observer.humidity,
            0.55,                           // visual wavelength (μm)
            &aob, &zob, &hob, &dob, &rob
        )
        guard status >= 0 else { throw AstroKitError.erfaError(status) }

        let actuallyRefracted = refracted && phpa > 0
        return SphericalPosition(
            longitude: aob,
            latitude: .pi / 2.0 - zob,
            frame: .horizontal(observer: observer, jd: jd, refracted: actuallyRefracted)
        )
    }

    // MARK: Private: origin shifting

    private func shiftOrigin(to target: CoordinateOrigin) throws -> SphericalPosition {
        switch (origin, target) {

        case (.geocentric, .topocentric):
            // ERFA's eraAtco13 / eraAtio13 handle the geocentric → topocentric
            // projection internally when converting to the horizontal frame.
            // No explicit origin-shift vector is needed — pass through.
            return self

        case (.heliocentric, .geocentric),
             (.heliocentric, .topocentric):
            // Heliocentric → geocentric: subtract Earth's heliocentric position vector.
            // (.topocentric differences are sub-arcsecond for most bodies and are
            //  handled by ERFA's diurnal-parallax step inside the horizontal-frame transform.)
            guard case .ecliptic(let equinox, _) = frame else {
                throw AstroKitError.unsupportedTransformation
            }
            guard let provider = SphericalPosition.ephemeris else {
                throw AstroKitError.noEphemerisProvider
            }
            let earth = provider.earthHeliocentricEclipticPosition(at: equinox)
            return SphericalPosition.heliocentricToGeocentric(body: self, earth: earth, at: equinox)

        default:
            throw AstroKitError.unsupportedTransformation
        }
    }

    // Cartesian heliocentric subtraction: body_helio − earth_helio = body_geocentric.
    // Equivalent to eraS2p + eraPmp + eraP2s in ERFA.
    private static func heliocentricToGeocentric(
        body: SphericalPosition, earth: SphericalPosition, at jd: JulianDay
    ) -> SphericalPosition {
        let r = body.distance ?? 0
        let cosB  = cos(body.latitude)
        let px = r * cosB * cos(body.longitude)
        let py = r * cosB * sin(body.longitude)
        let pz = r * sin(body.latitude)

        let re    = earth.distance ?? 0
        let cosBe = cos(earth.latitude)
        let ex = re * cosBe * cos(earth.longitude)
        let ey = re * cosBe * sin(earth.longitude)
        let ez = re * sin(earth.latitude)

        let gx = px - ex, gy = py - ey, gz = pz - ez
        let dist = sqrt(gx*gx + gy*gy + gz*gz)
        let lon  = (atan2(gy, gx) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let lat  = dist > 0 ? asin(gz / dist) : 0.0

        return SphericalPosition(longitude: lon, latitude: lat, distance: dist,
                                 frame: .ecliptic(equinox: jd))
    }
}


// MARK: - CatalogueObject transforms

extension CatalogueObject {

    /// Compute the position in the requested frame, applying proper motion,
    /// parallax, and radial velocity as appropriate.
    ///
    /// The catalogue position is first propagated from its `epoch` to J2000.0
    /// (the reference epoch ERFA expects), then the full astrometric pipeline
    /// is applied.
    public func toSphericalPosition(in frame: CoordinateFrame,
                                      at observationJD: JulianDay = .j2000) throws -> SphericalPosition {
        guard case .equatorial(.icrs, _) = catalogPosition.frame else {
            throw AstroKitError.unsupportedTransformation
        }

        // Propagate from catalogue epoch to J2000.0 — ERFA expects J2000.0 ICRS positions.
        let j2000 = catalogEpoch == .j2000 ? self : propagated(toEpoch: .j2000)

        let rc = j2000.catalogPosition.longitude
        let dc = j2000.catalogPosition.latitude
        let (pr, pd) = TransformHelper.erfaProperMotion(pm: j2000.properMotion, dec: dc)
        let px = (j2000.parallax ?? 0.0) / 1000.0
        let rv = j2000.radialVelocity ?? 0.0

        switch frame {

        case .equatorial(.icrs, _):
            // Apply proper motion to the observation epoch when kinematic data is available.
            let (rcObs, dcObs, pxObs) = TransformHelper.propagateToEpoch(
                rc: rc, dc: dc, pr: pr, pd: pd, px: px, rv: rv,
                from: .j2000, to: observationJD
            )
            return SphericalPosition(
                longitude: rcObs, latitude: dcObs,
                distance: TransformHelper.parallaxArcSecToAU(pxObs),
                frame: .equatorial(.icrs)
            )

        case .equatorial(.cirs(let jd), _):
            var ri: Double = 0, di: Double = 0, eo: Double = 0
            eraAtci13(rc, dc, pr, pd, px, rv, jd.value, 0.0, &ri, &di, &eo)
            return SphericalPosition(longitude: ri, latitude: di,
                                     distance: TransformHelper.parallaxArcSecToAU(px), frame: frame)

        case .equatorial(.apparentOfDate(let jd), _):
            var ri: Double = 0, di: Double = 0, eo: Double = 0
            eraAtci13(rc, dc, pr, pd, px, rv, jd.value, 0.0, &ri, &di, &eo)
            let raApp = eraAnp(ri - eo)
            return SphericalPosition(longitude: raApp, latitude: di,
                                     distance: TransformHelper.parallaxArcSecToAU(px), frame: frame)

        case .horizontal(let observer, let jd, let refracted):
            var aob: Double = 0, zob: Double = 0, hob: Double = 0
            var dob: Double = 0, rob: Double = 0, eo:  Double = 0

            let phpa = TransformHelper.effectivePressure(observer: observer, refracted: refracted)

            let status = eraAtco13(
                rc, dc, pr, pd, px, rv,
                jd.value, 0.0,
                0.0,
                observer.longitude, observer.latitude, observer.height,
                0.0, 0.0,
                phpa, observer.temperature, observer.humidity, 0.55,
                &aob, &zob, &hob, &dob, &rob, &eo
            )
            guard status >= 0 else { throw AstroKitError.erfaError(status) }

            let actuallyRefracted = refracted && phpa > 0
            return SphericalPosition(
                longitude: aob,
                latitude: .pi / 2.0 - zob,
                distance: TransformHelper.parallaxArcSecToAU(px),
                frame: .horizontal(observer: observer, jd: jd, refracted: actuallyRefracted)
            )

        case .galactic(_):
            // Apply proper motion to the observation epoch, then rotate to galactic.
            let (rcObs, dcObs, pxObs) = TransformHelper.propagateToEpoch(
                rc: rc, dc: dc, pr: pr, pd: pd, px: px, rv: rv,
                from: .j2000, to: observationJD
            )
            var l: Double = 0, b: Double = 0
            eraIcrs2g(rcObs, dcObs, &l, &b)
            return SphericalPosition(longitude: l, latitude: b,
                                     distance: TransformHelper.parallaxArcSecToAU(pxObs), frame: .galactic())

        case .ecliptic(let jd, _):
            var l: Double = 0, b: Double = 0
            eraEqec06(jd.value, 0.0, rc, dc, &l, &b)
            return SphericalPosition(longitude: l, latitude: b,
                                     distance: TransformHelper.parallaxArcSecToAU(px), frame: frame)

        default:
            throw AstroKitError.unsupportedTransformation
        }
    }

    /// Return a new `CatalogueObject` with the position and proper motion
    /// propagated to a different Julian epoch using `eraStarpm`.
    public func propagated(toEpoch targetEpoch: JulianYear) -> CatalogueObject {
        let dec = catalogPosition.latitude
        let (pmr, pmd) = TransformHelper.erfaProperMotion(pm: properMotion, dec: dec)
        let px  = (parallax ?? 0.0) / 1000.0
        let rv  = radialVelocity ?? 0.0

        let ep1 = catalogEpoch.julianDay.value
        let ep2 = targetEpoch.julianDay.value

        var ra2: Double = 0, dec2: Double = 0
        var pmr2: Double = 0, pmd2: Double = 0, px2: Double = 0, rv2: Double = 0

        let status = eraStarpm(
            catalogPosition.longitude, dec,
            pmr, pmd, px, rv,
            ep1, 0.0, ep2, 0.0,
            &ra2, &dec2, &pmr2, &pmd2, &px2, &rv2
        )
        guard status >= 0 else { return self }

        let cosLat2 = cos(dec2)
        return CatalogueObject(
            position: SphericalPosition(longitude: ra2, latitude: dec2,
                                        frame: .equatorial(.icrs)),
            epoch: targetEpoch,
            properMotion: ProperMotion(
                ra:  pmr2 * cosLat2 / TransformHelper.masToRad,
                dec: pmd2 / TransformHelper.masToRad
            ),
            parallax: px2 * 1000.0,
            radialVelocity: rv2
        )
    }
}


