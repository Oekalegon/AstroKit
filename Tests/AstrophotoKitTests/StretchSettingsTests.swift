import Foundation
import Testing
@testable import AstrophotoKit

@Suite("StretchSettings — identity")
struct StretchSettingsIdentityTests {

    @Test("identity has inputBlack=0, inputWhite=1")
    func identityValues() {
        let s = StretchSettings.identity
        #expect(s.inputBlack == 0.0)
        #expect(s.inputWhite == 1.0)
    }

    @Test("identity.isIdentity is true")
    func identityIsIdentity() {
        #expect(StretchSettings.identity.isIdentity)
    }

    @Test("non-identity stretch reports isIdentity false")
    func nonIdentityIsNotIdentity() {
        #expect(!StretchSettings(inputBlack: 0.0, inputWhite: 0.5).isIdentity)
        #expect(!StretchSettings(inputBlack: 0.1, inputWhite: 1.0).isIdentity)
    }

    @Test("identity effective(sliderNorm:) is a pass-through")
    func identityPassThrough() {
        let s = StretchSettings.identity
        #expect(s.effective(sliderNorm: 0.0) == 0.0)
        #expect(s.effective(sliderNorm: 0.5) == 0.5)
        #expect(s.effective(sliderNorm: 1.0) == 1.0)
    }
}

@Suite("StretchSettings — composition")
struct StretchSettingsCompositionTests {

    @Test("effective maps slider 0→inputBlack, 1→inputWhite")
    func effectiveEndpoints() {
        let s = StretchSettings(inputBlack: 0.1, inputWhite: 0.3)
        #expect(abs(s.effective(sliderNorm: 0.0) - 0.1) < 1e-6)
        #expect(abs(s.effective(sliderNorm: 1.0) - 0.3) < 1e-6)
    }

    @Test("effective midpoint is midpoint of [inputBlack, inputWhite]")
    func effectiveMidpoint() {
        let s = StretchSettings(inputBlack: 0.2, inputWhite: 0.6)
        // slider=0.5 → 0.2 + 0.5*(0.6-0.2) = 0.4
        #expect(abs(s.effective(sliderNorm: 0.5) - 0.4) < 1e-6)
    }

    @Test("effective with identity stretch equals sliderNorm unchanged")
    func effectiveIdentityPassThrough() {
        let s = StretchSettings.identity
        for norm: Float in [0.0, 0.25, 0.5, 0.75, 1.0] {
            #expect(abs(s.effective(sliderNorm: norm) - norm) < 1e-6)
        }
    }
}

@Suite("StretchSettings — normalize")
struct StretchSettingsNormalizeTests {

    @Test("normalize: display is unchanged (effective values preserved)")
    func normalizePreservesDisplay() {
        let original = StretchSettings.identity
        // User set sliders to black=0.0, white=0.1 (10 % of range)
        let blackNorm: Float = 0.0
        let whiteNorm: Float = 0.1

        let effectiveBlackBefore = original.effective(sliderNorm: blackNorm)
        let effectiveWhiteBefore = original.effective(sliderNorm: whiteNorm)

        let normalized = original.normalized(sliderBlackNorm: blackNorm, sliderWhiteNorm: whiteNorm)

        // After normalize sliders reset to 0 and 1
        let effectiveBlackAfter = normalized.effective(sliderNorm: 0.0)
        let effectiveWhiteAfter = normalized.effective(sliderNorm: 1.0)

        #expect(abs(effectiveBlackAfter - effectiveBlackBefore) < 1e-6)
        #expect(abs(effectiveWhiteAfter - effectiveWhiteBefore) < 1e-6)
    }

    @Test("normalize on identity with full sliders returns identity")
    func normalizeIdentityFullSliders() {
        let result = StretchSettings.identity.normalized(sliderBlackNorm: 0.0, sliderWhiteNorm: 1.0)
        #expect(result.isIdentity)
    }

    @Test("normalize twice: second normalize on identity sliders is a no-op")
    func normalizeTwiceNoOp() {
        let first = StretchSettings.identity.normalized(sliderBlackNorm: 0.0, sliderWhiteNorm: 0.2)
        // After first normalize, sliders reset to (0, 1)
        let second = first.normalized(sliderBlackNorm: 0.0, sliderWhiteNorm: 1.0)
        #expect(abs(second.inputBlack - first.inputBlack) < 1e-6)
        #expect(abs(second.inputWhite - first.inputWhite) < 1e-6)
    }

    @Test("normalize chains: two 10 % reductions reach 1 % of original range")
    func normalizeChain() {
        // First: take 0–10 % → normalize
        let first = StretchSettings.identity.normalized(sliderBlackNorm: 0.0, sliderWhiteNorm: 0.1)
        // Second: within that, take 0–10 % → normalize → should be 0–1 % of original
        let second = first.normalized(sliderBlackNorm: 0.0, sliderWhiteNorm: 0.1)
        #expect(abs(second.inputBlack - 0.0) < 1e-6)
        #expect(abs(second.inputWhite - 0.01) < 1e-4)
    }
}

@Suite("StretchSettings — Codable")
struct StretchSettingsCodableTests {

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let original = StretchSettings(inputBlack: 0.123, inputWhite: 0.876)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StretchSettings.self, from: data)
        #expect(abs(decoded.inputBlack - original.inputBlack) < 1e-6)
        #expect(abs(decoded.inputWhite - original.inputWhite) < 1e-6)
    }

    @Test("identity round-trips through JSON")
    func identityJsonRoundTrip() throws {
        let data = try JSONEncoder().encode(StretchSettings.identity)
        let decoded = try JSONDecoder().decode(StretchSettings.self, from: data)
        #expect(decoded.isIdentity)
    }

    @Test("corrupted JSON (inputBlack >= inputWhite) throws on decode")
    func corruptedJSONThrows() throws {
        // Simulates a manually-edited or corrupted archive row.
        // The archive reads with `try? JSONDecoder().decode(...)` so this produces nil
        // rather than crashing or returning inverted stretch settings.
        let inverted = "{\"inputBlack\":0.9,\"inputWhite\":0.1}"
        let data = Data(inverted.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(StretchSettings.self, from: data)
        }

        let equal = "{\"inputBlack\":0.5,\"inputWhite\":0.5}"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(StretchSettings.self, from: Data(equal.utf8))
        }
    }
}

@Suite("StretchSettings — invariant")
struct StretchSettingsInvariantTests {

    @Test("zero-width stretch: effective returns constant regardless of slider — documents degenerate behavior")
    func zeroWidthStretchReturnsConstant() {
        // inputBlack == inputWhite is forbidden by init's precondition, but this test
        // documents what effective() produces with a zero-width range to justify
        // why the invariant matters: every slider position maps to the same output.
        let s = StretchSettings(inputBlack: 0.3, inputWhite: 0.3 + .ulpOfOne)
        // With an infinitesimally narrow stretch, all slider positions converge on ~0.3
        #expect(abs(s.effective(sliderNorm: 0.0) - 0.3) < 1e-6)
        #expect(abs(s.effective(sliderNorm: 0.5) - 0.3) < 1e-6)
        #expect(abs(s.effective(sliderNorm: 1.0) - 0.3) < 1e-6)
    }
}
