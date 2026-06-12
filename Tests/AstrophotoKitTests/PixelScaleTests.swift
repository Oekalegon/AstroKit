import Testing
import Foundation
@testable import AstrophotoKit

@Suite("PixelScale — arcsec/px from optics")
struct PixelScaleTests {

    @Test("computes the classic 206.265 × pixel / focal length formula")
    func basicFormula() throws {
        // ASI2600-class sensor (3.76 µm) on a 530 mm refractor.
        let scale = try #require(PixelScale.arcsecPerPixel(pixelSizeMicrons: 3.76, focalLengthMm: 530))
        #expect(abs(scale - 206.2648 * 3.76 / 530) < 1e-6)
        #expect(abs(scale - 1.4633) < 1e-4)
    }

    @Test("binning scales linearly")
    func binning() throws {
        let unbinned = try #require(PixelScale.arcsecPerPixel(pixelSizeMicrons: 3.76, focalLengthMm: 530))
        let binned   = try #require(PixelScale.arcsecPerPixel(pixelSizeMicrons: 3.76, binning: 2, focalLengthMm: 530))
        #expect(abs(binned - 2 * unbinned) < 1e-9)
    }

    @Test("non-positive inputs return nil")
    func invalidInputs() {
        #expect(PixelScale.arcsecPerPixel(pixelSizeMicrons: 0, focalLengthMm: 530) == nil)
        #expect(PixelScale.arcsecPerPixel(pixelSizeMicrons: -3.76, focalLengthMm: 530) == nil)
        #expect(PixelScale.arcsecPerPixel(pixelSizeMicrons: 3.76, focalLengthMm: 0) == nil)
        #expect(PixelScale.arcsecPerPixel(pixelSizeMicrons: 3.76, binning: 0, focalLengthMm: 530) == nil)
    }
}
