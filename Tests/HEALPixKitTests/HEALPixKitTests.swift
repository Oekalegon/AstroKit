import Testing
import HEALPixKit

@Suite("HEALPixKit")
struct HEALPixKitTests {

    // MARK: - Shared grids

    let ring64   = HEALPix(resolution: .nside64, scheme: .ring)
    let nested64 = HEALPix(resolution: .nside64, scheme: .nested)

    // ----------------------------------------------------------------
    // MARK: Resolution
    // ----------------------------------------------------------------

    @Test("nside=64 has npix=49152 and order=6")
    func resolutionProperties() {
        let res = Resolution(nside: 64)
        #expect(res.npix  == 49_152)
        #expect(res.order == 6)
    }

    @Test("Resolution(order:) round-trips nside")
    func resolutionOrderRoundTrip() {
        for order in 0...12 {
            let res = Resolution(order: order)
            #expect(res.order == order)
            #expect(res.nside == Int64(1) << order)
        }
    }

    @Test("All static convenience resolutions are valid")
    func staticResolutionsValid() {
        let all: [Resolution] = [
            .nside1, .nside2, .nside4, .nside8, .nside16, .nside32,
            .nside64, .nside128, .nside256, .nside512, .nside1024, .nside2048,
        ]
        for res in all {
            #expect(res.nside > 0)
            #expect((res.nside & (res.nside - 1)) == 0)  // power of 2
        }
    }

    // ----------------------------------------------------------------
    // MARK: PixelScheme
    // ----------------------------------------------------------------

    @Test("PixelScheme descriptions")
    func pixelSchemeDescriptions() {
        #expect(PixelScheme.ring.description   == "RING")
        #expect(PixelScheme.nested.description == "NESTED")
    }

    @Test("PixelScheme has exactly two cases")
    func pixelSchemeCaseCount() {
        #expect(PixelScheme.allCases.count == 2)
    }

    // ----------------------------------------------------------------
    // MARK: AngularCoordinate
    // ----------------------------------------------------------------

    @Test("AngularCoordinate declination is π/2 - theta")
    func angularCoordinateDeclination() {
        let coord = AngularCoordinate(theta: .pi / 3, phi: 1.0)
        #expect(abs(coord.declination - (.pi / 2 - .pi / 3)) < 1e-14)
    }

    @Test("init(rightAscension:declination:) matches init(theta:phi:)")
    func angularCoordinateEquatorialInit() {
        let ra: Double = 1.2, dec: Double = 0.5
        let a = AngularCoordinate(theta: .pi / 2 - dec, phi: ra)
        let b = AngularCoordinate(rightAscension: ra, declination: dec)
        #expect(a == b)
    }

    // ----------------------------------------------------------------
    // MARK: ang2pix round-trip — RING
    // ----------------------------------------------------------------

    @Test("RING: ang2pix / pix2ang round-trip near north pole")
    func ang2pixRingNorthPole() {
        let input = AngularCoordinate(theta: 0.01, phi: 0.5)
        let ipix  = ring64.pixel(at: input)
        let back  = ring64.angularCoordinate(of: ipix)

        // Returned coordinate is the pixel centre, not the exact input.
        // At nside=64 one pixel spans ≈ 0.015 rad; use 0.05 rad tolerance.
        #expect(abs(back.theta - input.theta) < 0.05)
        #expect(ipix >= 0 && ipix < ring64.npix)
    }

    @Test("RING: ang2pix / pix2ang round-trip at equator")
    func ang2pixRingEquator() {
        let equator = AngularCoordinate(theta: .pi / 2, phi: 1.0)
        let ipix    = ring64.pixel(at: equator)
        let back    = ring64.angularCoordinate(of: ipix)

        #expect(abs(back.theta - equator.theta) < 0.05)
        #expect(ipix >= 0 && ipix < ring64.npix)
    }

    // ----------------------------------------------------------------
    // MARK: ang2pix round-trip — NESTED
    // ----------------------------------------------------------------

    @Test("NESTED: ang2pix / pix2ang round-trip at equator")
    func ang2pixNestedEquator() {
        let equator = AngularCoordinate(theta: .pi / 2, phi: 2.5)
        let ipix    = nested64.pixel(at: equator)
        let back    = nested64.angularCoordinate(of: ipix)

        #expect(abs(back.theta - equator.theta) < 0.05)
        #expect(ipix >= 0 && ipix < nested64.npix)
    }

    // ----------------------------------------------------------------
    // MARK: Known values — nside=1
    // ----------------------------------------------------------------

    @Test("nside=1 RING has 12 pixels")
    func nside1TotalPixels() {
        let grid = HEALPix(resolution: .nside1, scheme: .ring)
        #expect(grid.npix == 12)
    }

    @Test("nside=1 RING: sampling covers all 12 pixels")
    func nside1AllPixelsCovered() {
        let grid = HEALPix(resolution: .nside1, scheme: .ring)
        let thetas: [Double] = [0.5, .pi / 2, .pi - 0.5]
        let phis:   [Double] = [0.2, .pi / 2 + 0.2, .pi + 0.2, 3 * .pi / 2 + 0.2]
        let pixels = Set(
            thetas.flatMap { t in
                phis.map { p in grid.pixel(at: AngularCoordinate(theta: t, phi: p)) }
            }
        )
        #expect(pixels.count == 12)
    }

    // ----------------------------------------------------------------
    // MARK: Vector round-trip
    // ----------------------------------------------------------------

    @Test("RING: vec2pix / pix2vec round-trip returns unit vector")
    func vec2pixRingRoundTrip() {
        let input  = (x: 0.0, y: 1.0, z: 0.0)    // equator, φ = π/2
        let ipix   = ring64.pixel(for: input)
        let output = ring64.vector(of: ipix)

        let len = (output.x*output.x + output.y*output.y + output.z*output.z).squareRoot()
        #expect(abs(len - 1.0) < 1e-10, "output vector length \(len)")

        let dot = input.x*output.x + input.y*output.y + input.z*output.z
        #expect(dot > 0.99, "input/output dot product \(dot)")
    }

    @Test("NESTED: vec2pix / pix2vec round-trip")
    func vec2pixNestedRoundTrip() {
        let input  = (x: 1.0, y: 0.0, z: 0.0)
        let ipix   = nested64.pixel(for: input)
        let output = nested64.vector(of: ipix)

        let dot = input.x*output.x + input.y*output.y + input.z*output.z
        #expect(dot > 0.99, "dot product \(dot)")
    }

    // ----------------------------------------------------------------
    // MARK: Scheme conversion
    // ----------------------------------------------------------------

    @Test("ring2nest2ring is identity")
    func ringNestRoundTrip() {
        let ipixRing   = ring64.pixel(at: AngularCoordinate(theta: 1.0, phi: 1.0))
        let ipixNested = ring64.convert(pixel: ipixRing, to: .nested)
        let backToRing = nested64.convert(pixel: ipixNested, to: .ring)
        #expect(backToRing == ipixRing)
    }

    @Test("convert(pixel:to:) is identity when target == source scheme")
    func convertIdentity() {
        let ipix = ring64.pixel(at: AngularCoordinate(theta: 1.0, phi: 2.0))
        #expect(ring64.convert(pixel: ipix, to: .ring) == ipix)
    }

    @Test("RING and NESTED pixels for same direction refer to same location")
    func ringSameAsNested() {
        let coord      = AngularCoordinate(theta: 1.0, phi: 2.3)
        let ringPix    = ring64.pixel(at: coord)
        let nestedPix  = nested64.pixel(at: coord)
        let nestedAsRing = nested64.convert(pixel: nestedPix, to: .ring)
        #expect(nestedAsRing == ringPix)
    }

    // ----------------------------------------------------------------
    // MARK: Cone queries
    // ----------------------------------------------------------------

    @Test("pixels(inConeAround:) contains the centre pixel")
    func coneQueryContainsCentre() {
        let coord  = AngularCoordinate(theta: .pi / 2, phi: 1.0)
        let centre = ring64.pixel(at: coord)
        let result = ring64.pixels(inConeAround: coord, radius: 0.1)
        #expect(result.contains(centre))
    }

    @Test("pixels(inConeAround:) returns more than one pixel for non-zero radius")
    func coneQueryReturnsMultiplePixels() {
        let coord  = AngularCoordinate(theta: .pi / 2, phi: 1.0)
        let result = ring64.pixels(inConeAround: coord, radius: 0.1)
        #expect(result.count > 1)
    }

    @Test("inclusive cone returns >= exact cone")
    func inclusiveConeIsSupersetOfExact() {
        let coord    = AngularCoordinate(theta: .pi / 2, phi: 2.0)
        let exact    = Set(ring64.pixels(inConeAround: coord, radius: 0.05))
        let inclusive = Set(ring64.pixels(inConeAround: coord, radius: 0.05, inclusive: true))
        #expect(inclusive.isSuperset(of: exact))
    }

    @Test("NESTED cone returns same sky coverage as RING cone")
    func coneQueryRingAndNestedConsistent() {
        let coord    = AngularCoordinate(theta: 1.0, phi: 3.0)
        let radius   = 0.08

        // Get RING pixels, convert to NESTED
        let ringPixels   = Set(ring64.pixels(inConeAround: coord, radius: radius))
        let asNested     = Set(ringPixels.map { ring64.convert(pixel: $0, to: .nested) })

        // Get NESTED pixels directly
        let nestedPixels = Set(nested64.pixels(inConeAround: coord, radius: radius))

        #expect(asNested == nestedPixels)
    }

    @Test("pixels(inConeAround:) with radius=0 returns the containing pixel")
    func coneQueryZeroRadius() {
        let coord  = AngularCoordinate(theta: .pi / 2, phi: 1.0)
        let centre = ring64.pixel(at: coord)
        let result = ring64.pixels(inConeAround: coord, radius: 0)
        // radius=0 may return the single containing pixel or nothing,
        // but must never return a pixel other than the containing one.
        #expect(result.count <= 1)
        #expect(result.isEmpty || result[0] == centre)
    }

    @Test("RING: ang2pix / pix2ang round-trip at south pole")
    func ang2pixRingSouthPole() {
        let south = AngularCoordinate(theta: .pi - 0.01, phi: 0.5)
        let ipix  = ring64.pixel(at: south)
        let back  = ring64.angularCoordinate(of: ipix)
        #expect(abs(back.theta - south.theta) < 0.05)
        #expect(ipix >= 0 && ipix < ring64.npix)
    }

    @Test("maxPixelRadius is positive and decreases with resolution")
    func maxPixelRadiusDecreases() {
        let coarse = HEALPix(resolution: .nside32,  scheme: .ring).maxPixelRadius
        let fine   = HEALPix(resolution: .nside128, scheme: .ring).maxPixelRadius
        #expect(coarse > fine)
        #expect(fine > 0)
    }

    // ----------------------------------------------------------------
    // MARK: HEALPix properties
    // ----------------------------------------------------------------

    @Test("HEALPix.npix matches Resolution.npix")
    func npixConsistency() {
        let res  = Resolution(nside: 128)
        let grid = HEALPix(resolution: res, scheme: .ring)
        #expect(grid.npix == res.npix)
        #expect(grid.npix == 12 * 128 * 128)
    }

    @Test("HEALPix is usable in a Set")
    func healpixHashable() {
        let a = HEALPix(resolution: .nside64, scheme: .ring)
        let b = HEALPix(resolution: .nside64, scheme: .ring)
        let c = HEALPix(resolution: .nside64, scheme: .nested)
        let set: Set<HEALPix> = [a, b, c]
        #expect(set.count == 2)   // a == b
    }
}
