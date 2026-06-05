import Testing
import Metal
@testable import AstrophotoKit

// MARK: - FITSImageToolsView.SampleKey

@Suite("FITSImageToolsView.SampleKey — identity")
struct SampleKeyTests {

    private func key(imageID: String?, textureID: ObjectIdentifier? = nil) -> FITSImageToolsView.SampleKey {
        FITSImageToolsView.SampleKey(
            cursor: SIMD2<Float>(0.5, 0.5),
            zoom: 1.0,
            panOffset: .zero,
            aspectRatio: SIMD2<Float>(1, 1),
            textureID: textureID,
            imageID: imageID
        )
    }

    @Test("different imageID produces distinct keys on the fitsImage path (nil textureID)")
    func differentImageIDProducesDistinctKey() {
        #expect(key(imageID: "frame-A") != key(imageID: "frame-B"))
    }

    @Test("identical imageID produces equal keys")
    func identicalImageIDProducesEqualKey() {
        #expect(key(imageID: "frame-A") == key(imageID: "frame-A"))
    }

    @Test("nil imageID cannot distinguish image swaps — documents the known limitation")
    func nilImageIDCannotDistinguishSwap() {
        // When the caller omits imageID, both keys are identical despite representing
        // different images. This is the documented limitation shared with sourceID.
        #expect(key(imageID: nil) == key(imageID: nil))
    }

    @Test("non-nil textureID distinguishes textures regardless of imageID")
    func textureIDDistinguishesTextures() {
        guard let device = MetalShared.device else { Issue.record("Metal unavailable"); return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        guard let texA = device.makeTexture(descriptor: desc),
              let texB = device.makeTexture(descriptor: desc) else {
            Issue.record("Texture creation failed"); return
        }
        let idA = ObjectIdentifier(texA as AnyObject)
        let idB = ObjectIdentifier(texB as AnyObject)
        #expect(key(imageID: nil, textureID: idA) != key(imageID: nil, textureID: idB))
    }
}

// MARK: - FITSCrossSectionView.makeSourceID

@Suite("FITSCrossSectionView.makeSourceID — stability and sensitivity")
struct CrossSectionSourceIDTests {

    private typealias ImageSize = (width: Int, height: Int, minValue: Float, maxValue: Float)
    private let size: ImageSize = (width: 100, height: 100, minValue: 0.0, maxValue: 1.0)

    private func id(imageID: String?, size: ImageSize? = nil) -> String {
        FITSCrossSectionView.makeSourceID(
            textureObjectID: nil,
            fitsImageSize: size ?? self.size,
            imageID: imageID,
            textureMinValue: 0,
            textureMaxValue: 1
        )
    }

    @Test("sourceID changes when imageID changes despite identical dimensions and value range")
    func changesOnImageIDSwap() {
        #expect(id(imageID: "version-A") != id(imageID: "version-B"))
    }

    @Test("sourceID is stable across calls with identical inputs")
    func stableWhenInputsUnchanged() {
        #expect(id(imageID: "version-A") == id(imageID: "version-A"))
    }

    @Test("nil imageID produces same ID as empty string — documents degenerate case")
    func nilImageIDCollidesWithEmpty() {
        // imageID ?? "" means nil and "" produce the same key — callers must
        // provide a non-nil, non-empty imageID to distinguish same-sized images.
        #expect(id(imageID: nil) == id(imageID: ""))
    }

    @Test("sourceID changes when image dimensions change")
    func changesOnDimensionChange() {
        let narrow: ImageSize = (width: 50, height: 100, minValue: 0.0, maxValue: 1.0)
        #expect(id(imageID: "v1") != id(imageID: "v1", size: narrow))
    }

    @Test("sourceID changes when fitsImage value range changes")
    func changesOnValueRangeChange() {
        // On the fitsImage path the range comes from fitsImageSize.minValue/maxValue,
        // not from the textureMinValue/textureMaxValue parameters (those are only used
        // on the texture path).
        let wideRange: ImageSize = (width: 100, height: 100, minValue: 0.0, maxValue: 65535.0)
        #expect(id(imageID: "v1") != id(imageID: "v1", size: wideRange))
    }

    @Test("texture path uses ObjectIdentifier not imageID")
    func texturePathUsesObjectIdentifier() {
        guard let device = MetalShared.device else { Issue.record("Metal unavailable"); return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        guard let texA = device.makeTexture(descriptor: desc),
              let texB = device.makeTexture(descriptor: desc) else {
            Issue.record("Texture creation failed"); return
        }
        let idA = FITSCrossSectionView.makeSourceID(
            textureObjectID: ObjectIdentifier(texA as AnyObject),
            fitsImageSize: nil, imageID: nil, textureMinValue: 0, textureMaxValue: 1)
        let idB = FITSCrossSectionView.makeSourceID(
            textureObjectID: ObjectIdentifier(texB as AnyObject),
            fitsImageSize: nil, imageID: nil, textureMinValue: 0, textureMaxValue: 1)
        #expect(idA != idB)
    }

    @Test("nil texture and nil fitsImage returns empty string")
    func emptyWhenNoSource() {
        let result = FITSCrossSectionView.makeSourceID(
            textureObjectID: nil, fitsImageSize: nil, imageID: nil,
            textureMinValue: 0, textureMaxValue: 1)
        #expect(result.isEmpty)
    }
}
