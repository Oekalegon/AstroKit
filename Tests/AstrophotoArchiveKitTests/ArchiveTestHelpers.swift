import Foundation
@testable import AstrophotoArchiveKit

/// Creates a valid minimal FITS file (NAXIS=0, no data block) at `url`.
/// CFITSIO accepts this as a well-formed file, and `FITSHeaderReader.read` returns
/// width=0, height=0 with default metadata — sufficient for archive ingestion tests.
func writeTinyFITS(
    to url: URL,
    imageType: String = "Light Frame",
    exptime: Double = 300,
    dateObs: String = "2025-03-25T08:25:40",
    stacked: Bool = false
) throws {
    var block = Data(repeating: 32, count: 2880)   // one header block, all spaces

    func card(_ text: String, slot: Int) {
        let padded = text.padding(toLength: 80, withPad: " ", startingAt: 0)
        for (i, byte) in padded.utf8.prefix(80).enumerated() {
            block[slot * 80 + i] = byte
        }
    }

    card("SIMPLE  =                    T / conforms to FITS standard", slot: 0)
    card("BITPIX  =                   16 / bits per pixel", slot: 1)
    card("NAXIS   =                    0 / no data array", slot: 2)
    card("IMAGETYP= '\(imageType)'", slot: 3)
    card("DATE-OBS= '\(dateObs)'", slot: 4)
    card(String(format: "EXPTIME = %24.1f / exposure in seconds", exptime), slot: 5)
    if stacked {
        card("STACKED =                    T / frame is a stack of multiple exposures", slot: 6)
        card("END", slot: 7)
    } else {
        card("END", slot: 6)
    }

    try block.write(to: url)
}

/// Creates a temporary archive directory, instantiates an `Archive` over it,
/// and returns both. The caller is responsible for cleanup:
///
///     defer { try? FileManager.default.removeItem(at: root) }
func makeTempArchive(prefix: String = "archive") throws -> (Archive, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (try Archive(configuration: ArchiveConfiguration(rootURL: root)), root)
}

/// Returns a unique temporary URL for a FITS file, e.g. `/tmp/label-<uuid>.fits`.
func tempFITSURL(_ label: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(label)-\(UUID().uuidString).fits")
}
