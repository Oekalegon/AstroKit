import ArgumentParser
import AstrophotoArchiveKit
import AstrophotoKit
import Foundation

struct SetPixelScale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-pixel-scale",
        abstract: "Bulk-set the pixel scale on frames and framesets matching a telescope and/or camera.",
        discussion: """
        Use this for frames whose FITS headers carry neither a scale keyword (PIXSCALE, \
        SCALE) nor the optics keywords (XPIXSZ, FOCALLEN) needed to derive one — e.g. \
        remote-observatory downloads. The scale is given directly with --arcsec-per-pixel, \
        or computed from --focal-length and --pixel-size as:

            arcsec/px = 206.265 × pixel_size[µm] × binning / focal_length[mm]

        Matching is by exact telescope (TELESCOP) and/or camera (INSTRUME) name as stored \
        in the archive; at least one is required. Stacked frames and framesets inherit \
        equipment names from their inputs, so they are updated by the same call. Framesets \
        whose equipment fields are empty are still filled in when their member frames \
        agree on a single pixel scale.

        By default only missing (NULL) values are filled. Pass --overwrite to replace \
        existing pixel scales as well.
        """
    )

    @OptionGroup var archiveOptions: ArchivePathOption

    @Option(name: .long, help: "Image scale in arcseconds per pixel.")
    var arcsecPerPixel: Double?

    @Option(name: .long, help: "Telescope focal length in mm (alternative to --arcsec-per-pixel, with --pixel-size).")
    var focalLength: Double?

    @Option(name: .long, help: "Unbinned sensor pixel size in µm (used with --focal-length).")
    var pixelSize: Double?

    @Option(name: .long, help: "Binning factor for the computed scale (default: 1).")
    var binning: Int = 1

    @Option(name: .long, help: "Exact telescope name to match (FITS TELESCOP).")
    var telescope: String?

    @Option(name: .long, help: "Exact camera name to match (FITS INSTRUME).")
    var camera: String?

    @Flag(name: .long, help: "Replace existing pixel scales too (default: only fill missing values).")
    var overwrite: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON.")
    var json: Bool = false

    func validate() throws {
        if arcsecPerPixel == nil && (focalLength == nil || pixelSize == nil) {
            throw ValidationError("Pass --arcsec-per-pixel, or both --focal-length and --pixel-size.")
        }
        if telescope == nil && camera == nil {
            throw ValidationError("Pass --telescope and/or --camera to select which frames to update.")
        }
    }

    func run() async throws {
        let scale: Double
        if let explicit = arcsecPerPixel {
            scale = explicit
        } else if let computed = PixelScale.arcsecPerPixel(
            pixelSizeMicrons: pixelSize!, binning: binning, focalLengthMm: focalLength!
        ) {
            scale = computed
        } else {
            throw ValidationError("--focal-length, --pixel-size, and --binning must all be positive.")
        }

        let config  = try archiveOptions.makeConfiguration()
        let archive = try Archive(configuration: config)
        let (frames, frameSets) = try await archive.setPixelScale(
            scale, telescope: telescope, camera: camera, overwrite: overwrite
        )

        if json {
            let obj: [String: Any] = [
                "arcsec_per_pixel":   scale,
                "frames_updated":     frames,
                "framesets_updated":  frameSets,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
            print(String(data: data, encoding: .utf8)!)
        } else {
            print(String(format: "Pixel scale %.4f\"/px", scale))
            print("  Frames updated:    \(frames)")
            print("  Framesets updated: \(frameSets)")
        }
    }
}
