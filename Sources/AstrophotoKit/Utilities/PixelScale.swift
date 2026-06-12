import Foundation

/// Conversion between camera/telescope optics and image scale on the sky.
public enum PixelScale {
    /// Arcseconds per radian (180 × 3600 / π).
    public static let arcsecPerRadian = 206_264.806_247_096_36

    /// Computes the image scale in arcseconds per pixel from the physical
    /// pixel size and the telescope focal length:
    ///
    ///     arcsec/px = 206.265 × pixelSize[µm] × binning / focalLength[mm]
    ///
    /// `pixelSizeMicrons` is the unbinned sensor pixel size (FITS `XPIXSZ`);
    /// pass `binning` (FITS `XBINNING`) when the frame was binned.
    ///
    /// - Returns: The image scale in arcsec/px, or `nil` when any input is
    ///   non-positive.
    public static func arcsecPerPixel(
        pixelSizeMicrons: Double,
        binning: Int = 1,
        focalLengthMm: Double
    ) -> Double? {
        guard pixelSizeMicrons > 0, binning > 0, focalLengthMm > 0 else { return nil }
        // µm / mm = 1e-3, so the radian→arcsec factor reduces to 206.265.
        return arcsecPerRadian * pixelSizeMicrons * Double(binning) / (focalLengthMm * 1000)
    }
}
