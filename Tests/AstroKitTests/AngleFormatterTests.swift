import Testing
import Foundation
import AstroKit

@Suite("AngleFormatter")
struct AngleFormatterTests {

    // Sirius: RA 6h 45m 08.9s
    let siriusRA  = (6.0 + 45.0/60 + 8.9/3600) * 15 * .pi / 180
    // Sirius: Dec −16° 42′ 58.0″
    let siriusDec = -(16.0 + 42.0/60 + 58.0/3600) * .pi / 180
    // Angle equal to exactly 2 arcminutes 13 arcseconds (for DMS/SDMS secondary tests)
    let twoArcMin13ArcSec = (2.0/60 + 13.0/3600) * .pi / 180
    // Angle equal to exactly 2 time-minutes 13 time-seconds (for HMS secondary tests)
    // 2m13s = 133 time-seconds = 133/3600 hours × 15 deg/hr
    let twoTimeMins13TimeSecs = (133.0 / 3600.0) * 15.0 * .pi / 180
    // Small angle: exactly 4.32 arcseconds
    let fourPointThreeTwoArcSec = (4.32 / 3600) * .pi / 180

    // MARK: - format(_:) method

    @Test("format(_:) and string(from:) return the same value")
    func formatAndStringFromAreEquivalent() {
        let f = AngleFormatter(format: .hms, precision: 4)
        #expect(f.format(siriusRA) == f.string(from: siriusRA))
    }

    // MARK: - HMS, startComponent = .primary (default)

    @Test("HMS precision=1 shows only hours")
    func hmsPrecision1() {
        #expect(AngleFormatter(format: .hms, precision: 1).format(siriusRA) == "06h")
    }

    @Test("HMS precision=2 shows hours and minutes")
    func hmsPrecision2() {
        #expect(AngleFormatter(format: .hms, precision: 2).format(siriusRA) == "06h45m")
    }

    @Test("HMS precision=3 shows integer seconds (truncated, not rounded)")
    func hmsPrecision3() {
        // 6h 45m 08.9s — integer part is 08, not 09
        #expect(AngleFormatter(format: .hms, precision: 3).format(siriusRA) == "06h45m08s")
    }

    @Test("HMS precision=4 uses unit symbol as decimal separator")
    func hmsPrecision4() {
        #expect(AngleFormatter(format: .hms, precision: 4).format(siriusRA) == "06h45m08s9")
    }

    @Test("HMS zero angle")
    func hmsZero() {
        #expect(AngleFormatter(format: .hms, precision: 1).format(0) == "00h")
        #expect(AngleFormatter(format: .hms, precision: 3).format(0) == "00h00m00s")
        #expect(AngleFormatter(format: .hms, precision: 4).format(0) == "00h00m00s0")
    }

    @Test("HMS wraps 2π to the same string as 0")
    func hmsWrap() {
        let f = AngleFormatter(format: .hms, precision: 4)
        #expect(f.format(0) == f.format(2 * Double.pi))
    }

    // MARK: - HMS, startComponent = .secondary (minutes first)

    @Test("HMS secondary precision=1 shows only minutes")
    func hmsSecondaryPrecision1() {
        let f = AngleFormatter(format: .hms, precision: 1, startComponent: .secondary)
        #expect(f.format(twoTimeMins13TimeSecs) == "2m")
    }

    @Test("HMS secondary precision=2 shows minutes + integer seconds")
    func hmsSecondaryPrecision2() {
        let f = AngleFormatter(format: .hms, precision: 2, startComponent: .secondary)
        #expect(f.format(twoTimeMins13TimeSecs) == "2m13s")
    }

    @Test("HMS secondary precision=3 shows minutes + seconds with 1 decimal place")
    func hmsSecondaryPrecision3() {
        let f = AngleFormatter(format: .hms, precision: 3, startComponent: .secondary)
        #expect(f.format(twoTimeMins13TimeSecs) == "2m13s0")
    }

    // MARK: - HMS, startComponent = .tertiary (seconds first)

    @Test("HMS tertiary precision=1 shows integer seconds")
    func hmsTertiaryPrecision1() {
        let f = AngleFormatter(format: .hms, precision: 1, startComponent: .tertiary)
        // 4.32″ in hours → totalSec = 4.32 / 15 s ... actually these are HMS,
        // so let's use a time angle. Use an angle of 8.9s (just seconds).
        let eightPointNineSec = (8.9 / 3600) * 15 * .pi / 180
        #expect(f.format(eightPointNineSec) == "8s")  // truncated, not 9
    }

    // MARK: - DMS, startComponent = .secondary (arcminutes first)

    @Test("DMS secondary precision=1 shows only arcminutes")
    func dmsSecondaryPrecision1() {
        let f = AngleFormatter(format: .dms, precision: 1, startComponent: .secondary)
        #expect(f.format(twoArcMin13ArcSec) == "2′")
    }

    @Test("DMS secondary precision=2 shows arcminutes + integer arcseconds")
    func dmsSecondaryPrecision2() {
        let f = AngleFormatter(format: .dms, precision: 2, startComponent: .secondary)
        #expect(f.format(twoArcMin13ArcSec) == "2′13″")
    }

    // MARK: - DMS, startComponent = .tertiary (arcseconds first)

    @Test("DMS tertiary shows 4\"32 for a 4.32-arcsecond angle")
    func dmsTertiaryFourPointThreeTwo() {
        // 4.32″ → tertiary precision=3 → 2 decimal places → "4″32"
        let f = AngleFormatter(format: .dms, precision: 3, startComponent: .tertiary)
        #expect(f.format(fourPointThreeTwoArcSec) == "4″32")
    }

    @Test("DMS tertiary precision=1 gives integer arcseconds")
    func dmsTertiaryPrecision1() {
        let f = AngleFormatter(format: .dms, precision: 1, startComponent: .tertiary)
        // 4.32″ → integer → "4″"
        #expect(f.format(fourPointThreeTwoArcSec) == "4″")
    }

    // MARK: - SDMS (signed)

    @Test("SDMS precision=4 formats Sirius Dec with unit-as-separator")
    func sdmsPrecision4() {
        let s = AngleFormatter(format: .sdms, precision: 4).format(siriusDec)
        #expect(s == "-16°42′58″0", "Got: \(s)")
    }

    @Test("SDMS positive declination has '+' prefix")
    func sdmsPositive() {
        let s = AngleFormatter(format: .sdms, precision: 2).format(38.78 * .pi / 180)
        #expect(s.hasPrefix("+"))
    }

    @Test("SDMS precision=1 shows only degrees with sign")
    func sdmsPrecision1() {
        #expect(AngleFormatter(format: .sdms, precision: 1).format(siriusDec) == "-16°")
    }

    // MARK: - parse(_:) / double(from:)

    @Test("parse: HMS round-trip restores original value within 1 decimal time-second")
    func parseHmsRoundTrip() throws {
        let f = AngleFormatter(format: .hms, precision: 4)
        let parsed = try #require(f.parse(f.format(siriusRA)))
        // 0.05 time-seconds ≈ 3.6e-6 rad — well within 1 decimal time-second precision
        #expect(abs(parsed - siriusRA) < 1e-5, "Round-trip error \(abs(parsed - siriusRA)) rad")
    }

    @Test("parse: SDMS round-trip preserves sign and magnitude")
    func parseSdmsRoundTrip() throws {
        let f = AngleFormatter(format: .sdms, precision: 4)
        let parsed = try #require(f.parse(f.format(siriusDec)))
        #expect(abs(parsed - siriusDec) < 1e-5, "Round-trip error \(abs(parsed - siriusDec)) rad")
    }

    @Test("parse: HMS precision=2 string round-trips to nearest minute")
    func parseHmsPrecision2() throws {
        let f = AngleFormatter(format: .hms, precision: 2)
        let expected = (6.0 + 45.0/60.0) * .pi / 12.0   // 6h 45m exactly
        let parsed = try #require(f.parse(f.format(siriusRA)))
        #expect(abs(parsed - expected) < 1e-10)
    }

    @Test("parse: HMS secondary 2m13s returns correct angle")
    func parseHmsSecondary() throws {
        let f = AngleFormatter(format: .hms, precision: 2, startComponent: .secondary)
        let parsed = try #require(f.parse("2m13s"))
        #expect(abs(parsed - twoTimeMins13TimeSecs) < 1e-10)
    }

    @Test("parse: DMS tertiary 4″32 returns 4.32 arcseconds")
    func parseDmsTertiary() throws {
        let f = AngleFormatter(format: .dms, precision: 3, startComponent: .tertiary)
        let parsed = try #require(f.parse("4″32"))
        #expect(abs(parsed - fourPointThreeTwoArcSec) < 1e-12)
    }

    @Test("parse: returns nil for string with no unit symbols")
    func parseNoUnitsReturnsNil() {
        let f = AngleFormatter(format: .hms, precision: 4)
        #expect(f.parse("") == nil)
        #expect(f.parse("123.45") == nil)
    }

    @Test("parse: returns nil for malformed string")
    func parseMalformedReturnsNil() {
        #expect(AngleFormatter(format: .hms, precision: 4).parse("abch12m") == nil)
    }

    @Test("double(from:) is an alias for parse(_:)")
    func doubleFromIsAlias() {
        let f = AngleFormatter(format: .hms, precision: 4)
        let s = f.format(siriusRA)
        #expect(f.double(from: s) == f.parse(s))
    }

    // MARK: - DMS (unsigned)

    @Test("DMS uses 3-digit degree field and has no sign")
    func dmsUnsigned() {
        let f = AngleFormatter(format: .dms, precision: 1)
        #expect(f.format(123 * .pi / 180) == "123°")
        #expect(f.format(5   * .pi / 180) == "005°")
        let s = f.format(siriusDec)
        #expect(!s.hasPrefix("+") && !s.hasPrefix("-"))
    }

    // MARK: - requiresSign

    @Test("requiresSign defaults to true for .sdms, false for .dms and .hms")
    func requiresSignDefaults() {
        #expect(AngleFormatter(format: .sdms).requiresSign == true)
        #expect(AngleFormatter(format: .dms).requiresSign == false)
        #expect(AngleFormatter(format: .hms).requiresSign == false)
    }

    @Test("requiresSign can be overridden: .dms with sign")
    func requiresSignOverriddenOn() {
        let f = AngleFormatter(format: .dms, precision: 1, requiresSign: true)
        let s = f.format(30 * .pi / 180)
        #expect(s.hasPrefix("+"), "Expected '+' prefix, got: \(s)")
    }

    @Test("requiresSign can be overridden: .sdms without sign")
    func requiresSignOverriddenOff() {
        let f = AngleFormatter(format: .sdms, precision: 1, requiresSign: false)
        let s = f.format(30 * .pi / 180)
        #expect(!s.hasPrefix("+") && !s.hasPrefix("-"), "Expected no sign, got: \(s)")
    }

    @Test("requiresSign=true uses 2-digit degree field; false uses 3-digit")
    func requiresSignAffectsDegreeWidth() {
        let signed   = AngleFormatter(format: .dms, precision: 1, requiresSign: true)
        let unsigned = AngleFormatter(format: .dms, precision: 1, requiresSign: false)
        #expect(signed.format(5 * .pi / 180)   == "+05°")
        #expect(unsigned.format(5 * .pi / 180) == "005°")
    }

    // MARK: - mas format

    @Test("mas precision=1 gives integer milliarcseconds")
    func masPrecision1() {
        // 1 arcsecond = 1000 mas
        let oneArcSec = .pi / (180.0 * 3600.0)
        let f = AngleFormatter(format: .mas, precision: 1)
        #expect(f.format(oneArcSec) == "1000 mas")
    }

    @Test("mas precision=4 gives 3 decimal places")
    func masPrecision4() {
        let val = 1.234 * .pi / (180.0 * 3_600_000.0)
        let f = AngleFormatter(format: .mas, precision: 4)
        let s = f.format(val)
        #expect(s == "1.234 mas", "Got: \(s)")
    }

    @Test("mas parse round-trip")
    func masParseRoundTrip() throws {
        let val = 567.89 * .pi / (180.0 * 3_600_000.0)
        let f   = AngleFormatter(format: .mas, precision: 3)
        let str = f.format(val)
        let parsed = try #require(f.parse(str))
        #expect(abs(parsed - val) < 1e-20, "Round-trip error: \(abs(parsed - val))")
    }

    @Test("mas parse returns nil for non-mas string")
    func masParseRejectsUnrelated() {
        #expect(AngleFormatter(format: .mas, precision: 2).parse("06h45m") == nil)
    }

    // MARK: - µas format

    @Test("µas precision=1 gives integer microarcseconds")
    func µasPrecision1() {
        // 1 milliarcsecond = 1000 µas
        let oneMas = .pi / (180.0 * 3_600_000.0)
        let f = AngleFormatter(format: .µas, precision: 1)
        #expect(f.format(oneMas) == "1000 µas")
    }

    @Test("µas parse round-trip")
    func µasParseRoundTrip() throws {
        let val = 12345.678 * .pi / (180.0 * 3_600_000_000.0)
        let f   = AngleFormatter(format: .µas, precision: 4)
        let str = f.format(val)
        let parsed = try #require(f.parse(str))
        #expect(abs(parsed - val) < 1e-24, "Round-trip error: \(abs(parsed - val))")
    }

    // MARK: - ParseableFormatStyle

    @Test("ParseableFormatStyle: parseStrategy.parse inverts format")
    func parseableFormatStyleRoundTrip() throws {
        let f      = AngleFormatter(format: .hms, precision: 4)
        let result = try f.parseStrategy.parse(f.format(siriusRA))
        #expect(abs(result - siriusRA) < 1e-5)
    }

    @Test("ParseableFormatStyle: parseStrategy.parse throws on invalid input")
    func parseableFormatStyleThrows() {
        let f = AngleFormatter(format: .hms, precision: 4)
        #expect(throws: (any Error).self) { try f.parseStrategy.parse("not an angle") }
    }

    @Test("AngleFormatter is Hashable and Codable")
    func hashableAndCodable() throws {
        let f1 = AngleFormatter(format: .hms, precision: 3)
        let f2 = AngleFormatter(format: .hms, precision: 3)
        let f3 = AngleFormatter(format: .dms, precision: 3)
        #expect(f1 == f2)
        #expect(f1 != f3)
        let data    = try JSONEncoder().encode(f1)
        let decoded = try JSONDecoder().decode(AngleFormatter.self, from: data)
        #expect(decoded == f1)
    }
}
