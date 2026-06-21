// MARK: - PixelScheme

/// The pixel ordering scheme used by a HEALPix grid.
///
/// HEALPix supports two pixel orderings:
///
/// - ``ring``:   Pixels are numbered sequentially along iso-latitude rings
///               from north to south pole.  Convenient for spherical-harmonic
///               transforms and power-spectrum analysis.
///
/// - ``nested``: Pixels follow a quadtree hierarchy — each pixel at resolution
///               `nside` subdivides into four pixels at `2 × nside`.  Ideal for
///               nearest-neighbour queries and multi-resolution work.
///
/// Pass the desired scheme when constructing a ``HEALPix`` grid:
/// ```swift
/// let grid = HEALPix(resolution: .nside64, scheme: .ring)
/// ```
public enum PixelScheme: String, Sendable, Equatable, Hashable,
                         CaseIterable, CustomStringConvertible {

    /// ISO-latitude ring ordering.
    case ring

    /// Hierarchical quadtree (nested) ordering.
    case nested

    // MARK: CustomStringConvertible

    public var description: String {
        switch self {
        case .ring:   return "RING"
        case .nested: return "NESTED"
        }
    }
}
