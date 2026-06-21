import CHEALPix

// MARK: - HEALPix

/// A HEALPix grid — a specific combination of resolution and pixel-ordering scheme.
///
/// `HEALPix` is the single entry point for all pixel ↔ coordinate conversions.
/// Construct one instance and reuse it; all methods are purely functional.
///
/// ```swift
/// let grid = HEALPix(resolution: .nside64, scheme: .ring)
///
/// // Angular coordinate → pixel
/// let coord = AngularCoordinate(theta: 0.3, phi: 1.2)
/// let ipix  = grid.pixel(at: coord)                  // Int64
///
/// // Pixel → angular coordinate (round-trip to pixel centre)
/// let centre = grid.angularCoordinate(of: ipix)
///
/// // Unit vector → pixel
/// let ipix2  = grid.pixel(for: (x: 0.0, y: 1.0, z: 0.0))
///
/// // Pixel → unit vector
/// let vec    = grid.vector(of: ipix)                 // (x:, y:, z:)
///
/// // Scheme conversion
/// let nested = grid.convert(pixel: ipix, to: .nested)
/// ```
public struct HEALPix: Sendable, Equatable, Hashable, CustomStringConvertible {

    // MARK: Stored properties

    /// Resolution of this grid.
    public let resolution: Resolution

    /// Pixel ordering scheme of this grid.
    public let scheme: PixelScheme

    // MARK: Initialiser

    /// Create a HEALPix grid.
    ///
    /// - Parameters:
    ///   - resolution: The `nside` resolution parameter (must be a power of 2).
    ///   - scheme:     Pixel ordering: ``PixelScheme/ring`` or ``PixelScheme/nested``.
    public init(resolution: Resolution, scheme: PixelScheme) {
        self.resolution = resolution
        self.scheme     = scheme
    }

    // MARK: Convenience

    /// Total number of pixels: `12 × nside²`.
    public var npix: Int64 { resolution.npix }

    // MARK: - Angular coordinate conversions

    /// Return the pixel index containing the point `coordinate`.
    ///
    /// - Parameter coordinate: Angular position on the sphere.
    /// - Returns: Pixel index in [0, ``npix``).
    public func pixel(at coordinate: AngularCoordinate) -> Int64 {
        var ipix: Int = 0
        let n = Int(resolution.nside)
        withUnsafeMutablePointer(to: &ipix) { ptr in
            switch scheme {
            case .ring:   ang2pix_ring(n, coordinate.theta, coordinate.phi, ptr)
            case .nested: ang2pix_nest(n, coordinate.theta, coordinate.phi, ptr)
            }
        }
        return Int64(ipix)
    }

    /// Return the angular coordinate of the centre of pixel `ipix`.
    ///
    /// - Parameter ipix: Pixel index in [0, ``npix``).
    /// - Returns: Angular coordinate of the pixel centre.
    public func angularCoordinate(of ipix: Int64) -> AngularCoordinate {
        var theta = 0.0, phi = 0.0
        let n = Int(resolution.nside)
        withUnsafeMutablePointer(to: &theta) { tptr in
            withUnsafeMutablePointer(to: &phi) { pptr in
                switch scheme {
                case .ring:   pix2ang_ring(n, Int(ipix), tptr, pptr)
                case .nested: pix2ang_nest(n, Int(ipix), tptr, pptr)
                }
            }
        }
        return AngularCoordinate(theta: theta, phi: phi)
    }

    // MARK: - Vector conversions

    /// Return the pixel index containing the direction given by a unit 3-vector.
    ///
    /// The vector need not be normalised — healpix_cxx normalises internally.
    ///
    /// - Parameter vector: Direction as a named tuple `(x:y:z:)`.
    /// - Returns: Pixel index in [0, ``npix``).
    public func pixel(for vector: (x: Double, y: Double, z: Double)) -> Int64 {
        var arr: [Double] = [vector.x, vector.y, vector.z]
        var ipix: Int = 0
        let n = Int(resolution.nside)
        switch scheme {
        case .ring:   vec2pix_ring(n, &arr, &ipix)
        case .nested: vec2pix_nest(n, &arr, &ipix)
        }
        return Int64(ipix)
    }

    /// Return the unit 3-vector pointing at the centre of pixel `ipix`.
    ///
    /// - Parameter ipix: Pixel index in [0, ``npix``).
    /// - Returns: Named tuple `(x: Double, y: Double, z: Double)` on the unit sphere.
    public func vector(of ipix: Int64) -> (x: Double, y: Double, z: Double) {
        var arr = [Double](repeating: 0, count: 3)
        let n = Int(resolution.nside)
        switch scheme {
        case .ring:   pix2vec_ring(n, Int(ipix), &arr)
        case .nested: pix2vec_nest(n, Int(ipix), &arr)
        }
        return (x: arr[0], y: arr[1], z: arr[2])
    }

    // MARK: - Scheme conversion

    /// Convert a pixel index from this grid's scheme to `targetScheme`.
    ///
    /// When `targetScheme` matches the current scheme the pixel is returned unchanged.
    ///
    /// - Parameters:
    ///   - pixel:        Source pixel in this grid's ordering scheme.
    ///   - targetScheme: Target ordering scheme.
    /// - Returns: Equivalent pixel index in `targetScheme`.
    public func convert(pixel ipix: Int64, to targetScheme: PixelScheme) -> Int64 {
        guard targetScheme != scheme else { return ipix }
        var result: Int = 0
        let n = Int(resolution.nside)
        withUnsafeMutablePointer(to: &result) { ptr in
            switch scheme {
            case .ring:   ring2nest(n, Int(ipix), ptr)   // ring → nested
            case .nested: nest2ring(n, Int(ipix), ptr)   // nested → ring
            }
        }
        return Int64(result)
    }

    // MARK: - Cone / disc queries

    /// Maximum angular distance (in radians) between any pixel centre and its
    /// corners for this grid's resolution.
    ///
    /// Add this to a search radius before calling ``pixels(inConeAround:radius:inclusive:)``
    /// when you need to guarantee that every overlapping pixel is returned.
    public var maxPixelRadius: Double {
        healpix_max_pixrad(Int(resolution.nside))
    }

    /// Return the indices of all pixels whose **centres** lie within `radius`
    /// radians of `coordinate`.
    ///
    /// ```swift
    /// let grid   = HEALPix(resolution: .nside64, scheme: .ring)
    /// let centre = AngularCoordinate(rightAscension: ra, declination: dec)
    /// let pixels = grid.pixels(inConeAround: centre, radius: 0.1)  // ~5.7°
    /// ```
    ///
    /// - Parameters:
    ///   - coordinate: Centre of the search cone.
    ///   - radius:     Angular radius in radians.
    ///   - inclusive:  If `true`, also includes pixels that partially overlap
    ///                 the disc boundary (conservative — may return a few extra
    ///                 pixels near the edge). Default is `false`.
    /// - Returns: Array of pixel indices, sorted in the grid's ordering scheme.
    public func pixels(inConeAround coordinate: AngularCoordinate,
                       radius: Double,
                       inclusive: Bool = false) -> [Int64] {
        var ptr: UnsafeMutablePointer<Int>? = nil
        let n = Int(resolution.nside)
        let count: Int
        switch (scheme, inclusive) {
        case (.ring,   false): count = Int(query_disc_ring(n, coordinate.theta, coordinate.phi, radius, &ptr))
        case (.nested, false): count = Int(query_disc_nest(n, coordinate.theta, coordinate.phi, radius, &ptr))
        case (.ring,   true):  count = Int(query_disc_inclusive_ring(n, coordinate.theta, coordinate.phi, radius, &ptr))
        case (.nested, true):  count = Int(query_disc_inclusive_nest(n, coordinate.theta, coordinate.phi, radius, &ptr))
        }
        defer { healpix_free_pixels(ptr) }
        guard let p = ptr, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: count)).map(Int64.init)
    }

    // MARK: CustomStringConvertible

    public var description: String { "HEALPix(\(resolution), \(scheme))" }
}
