// MARK: - Resolution

/// The resolution of a HEALPix grid, parameterised by `nside`.
///
/// `nside` must be a positive power of 2 in the range \[1, 2²⁹\].
/// The grid contains `npix = 12 × nside²` pixels of equal area.
///
/// ```swift
/// let res = Resolution(nside: 512)
/// print(res.npix)   // 3_145_728
/// print(res.order)  // 9  (2^9 = 512)
/// ```
public struct Resolution: Sendable, Equatable, Hashable, CustomStringConvertible {

    // MARK: Stored property

    /// The HEALPix resolution parameter.  Always a power of 2 in [1, 2²⁹].
    public let nside: Int64

    // MARK: Initialisers

    /// Create a `Resolution` with the given `nside`.
    ///
    /// - Parameter nside: Must be a positive power of 2 in [1, 2²⁹].
    ///   Violating this constraint traps at runtime.
    public init(nside: Int64) {
        precondition(Resolution.isValid(nside),
                     "nside must be a power of 2 in [1, 2^29], got \(nside)")
        self.nside = nside
    }

    /// Create a `Resolution` from a HEALPix order (log₂(nside)).
    ///
    /// - Parameter order: Integer in [0, 29].
    public init(order: Int) {
        precondition((0...29).contains(order),
                     "HEALPix order must be in [0, 29], got \(order)")
        self.nside = Int64(1) << order
    }

    // MARK: Computed properties

    /// Total number of pixels: `12 × nside²`.
    public var npix: Int64 { 12 * nside * nside }

    /// The HEALPix order: `log₂(nside)`, an integer in [0, 29].
    public var order: Int { Int(nside).trailingZeroBitCount }

    // MARK: CustomStringConvertible

    public var description: String { "Nside=\(nside)" }

    // MARK: Common resolutions

    public static let nside1    = Resolution(nside: 1)       // 12 pixels
    public static let nside2    = Resolution(nside: 2)       // 48 pixels
    public static let nside4    = Resolution(nside: 4)       // 192 pixels
    public static let nside8    = Resolution(nside: 8)       // 768 pixels
    public static let nside16   = Resolution(nside: 16)      // 3 072 pixels
    public static let nside32   = Resolution(nside: 32)      // 12 288 pixels
    public static let nside64   = Resolution(nside: 64)      // 49 152 pixels
    public static let nside128  = Resolution(nside: 128)     // 196 608 pixels
    public static let nside256  = Resolution(nside: 256)     // 786 432 pixels
    public static let nside512  = Resolution(nside: 512)     // 3 145 728 pixels
    public static let nside1024 = Resolution(nside: 1024)    // ~12.6 M pixels
    public static let nside2048 = Resolution(nside: 2048)    // ~50.3 M pixels

    // MARK: Private validation

    private static func isValid(_ n: Int64) -> Bool {
        guard n > 0, n <= (1 << 29) else { return false }
        return (n & (n - 1)) == 0  // exactly one bit set
    }
}
