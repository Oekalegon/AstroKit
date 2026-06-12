#include <metal_stdlib>
using namespace metal;

/// Structure to hold star information for FWHM calculation
struct StarInfo {
    float centroidX;
    float centroidY;
    int regionSize;  // Region size for this star (based on major/minor axis)
};

/// Structure to hold moment results for a star
struct MomentResults {
    float m00;  // Zeroth moment (total windowed weight)
    float m10;  // First moment X
    float m01;  // First moment Y
    float mu20; // Second central moment X (variance, as measured under the window)
    float mu11; // Covariance (as measured under the window)
    float mu02; // Second central moment Y (variance, as measured under the window)
    float maxPixelValue; // Maximum pixel value in the region (for saturation detection)
    float windowSigma;   // Sigma of the Gaussian window used for the final measurement
};

/// Compute shader to calculate Gaussian-windowed image moments for a single star.
///
/// Each thread processes one star. The algorithm:
/// 1. Estimates the local background from a sigma-clipped annulus at the edge of
///    the measurement region, so residual nebulosity/sky does not inflate the moments.
/// 2. Computes intensity-weighted moments with a Gaussian window centred on the star
///    (SExtractor-style windowed moments). The window suppresses PSF wings, noise and
///    neighbouring stars — unwindowed second moments diverge for Moffat-like profiles.
/// 3. Iterates twice, re-centring the window and adapting its size to the star.
///
/// The window biases the measured variance: for a Gaussian star of variance σ*² measured
/// with a window of variance σw², the measured variance is (σ*⁻² + σw⁻²)⁻¹. The host code
/// inverts this analytically using the returned windowSigma.
kernel void calculate_star_moments(texture2d<float> inputTexture [[texture(0)]],
                                    device StarInfo* starInfoBuffer [[buffer(0)]],
                                    device MomentResults* momentResultsBuffer [[buffer(1)]],
                                    uint starIndex [[thread_position_in_grid]]) {
    // Get star information
    StarInfo star = starInfoBuffer[starIndex];
    int centerX = int(round(star.centroidX));
    int centerY = int(round(star.centroidY));

    // Use per-star region size
    int regionSize = star.regionSize;
    int halfSize = regionSize / 2;
    int textureWidth = int(inputTexture.get_width());
    int textureHeight = int(inputTexture.get_height());

    // Calculate region bounds
    int x0 = max(0, centerX - halfSize);
    int y0 = max(0, centerY - halfSize);
    int x1 = min(textureWidth, centerX + halfSize);
    int y1 = min(textureHeight, centerY + halfSize);

    int regionWidth = x1 - x0;
    int regionHeight = y1 - y0;

    if (regionWidth <= 0 || regionHeight <= 0) {
        momentResultsBuffer[starIndex] = MomentResults{0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
        return;
    }

    // --- Pass 1: local background from an annulus at the edge of the region ---
    // The annulus lies between 70% and 100% of halfSize from the nominal centre,
    // far enough from the star core that it samples mostly sky/nebulosity.
    float rIn = 0.7 * float(halfSize);
    float rOut = float(halfSize);
    float annulusSum = 0.0;
    float annulusSumSq = 0.0;
    int annulusCount = 0;
    float maxPixelValue = 0.0;

    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float value = inputTexture.read(uint2(x, y)).r;
            maxPixelValue = max(maxPixelValue, value);

            float dx = float(x) - star.centroidX;
            float dy = float(y) - star.centroidY;
            float dist = sqrt(dx * dx + dy * dy);
            if (dist >= rIn && dist <= rOut) {
                annulusSum += value;
                annulusSumSq += value * value;
                annulusCount++;
            }
        }
    }

    float localBackground = 0.0;
    if (annulusCount > 0) {
        float mean = annulusSum / float(annulusCount);
        float variance = max(0.0, annulusSumSq / float(annulusCount) - mean * mean);
        float stddev = sqrt(variance);

        // Sigma-clipped mean: reject annulus pixels more than 2σ from the mean
        // (faint stars falling in the annulus would otherwise bias the background high)
        float clippedSum = 0.0;
        int clippedCount = 0;
        for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
                float dx = float(x) - star.centroidX;
                float dy = float(y) - star.centroidY;
                float dist = sqrt(dx * dx + dy * dy);
                if (dist >= rIn && dist <= rOut) {
                    float value = inputTexture.read(uint2(x, y)).r;
                    if (fabs(value - mean) <= 2.0 * stddev) {
                        clippedSum += value;
                        clippedCount++;
                    }
                }
            }
        }
        localBackground = (clippedCount > 0) ? clippedSum / float(clippedCount) : mean;
    }

    // --- Pass 2: Gaussian-windowed moments, iterated with re-centring ---
    float cx = star.centroidX;
    float cy = star.centroidY;
    float sigmaW = max(2.0, float(halfSize) / 3.0);
    float m00 = 0.0;
    float mu20 = 0.0;
    float mu11 = 0.0;
    float mu02 = 0.0;

    for (int iter = 0; iter < 2; iter++) {
        float twoSigmaW2 = 2.0 * sigmaW * sigmaW;

        // First moments: re-centre the window on the windowed centroid
        float sum = 0.0;
        float sumX = 0.0;
        float sumY = 0.0;
        for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
                float value = max(inputTexture.read(uint2(x, y)).r - localBackground, 0.0);
                float dx = float(x) - cx;
                float dy = float(y) - cy;
                float weight = value * exp(-(dx * dx + dy * dy) / twoSigmaW2);
                sum += weight;
                sumX += weight * float(x);
                sumY += weight * float(y);
            }
        }

        if (sum <= 0.0) {
            momentResultsBuffer[starIndex] =
                MomentResults{0.0, 0.0, 0.0, 0.0, 0.0, 0.0, maxPixelValue, sigmaW};
            return;
        }

        cx = sumX / sum;
        cy = sumY / sum;

        // Second central moments about the updated centroid
        m00 = 0.0;
        mu20 = 0.0;
        mu11 = 0.0;
        mu02 = 0.0;
        for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
                float value = max(inputTexture.read(uint2(x, y)).r - localBackground, 0.0);
                float dx = float(x) - cx;
                float dy = float(y) - cy;
                float weight = value * exp(-(dx * dx + dy * dy) / twoSigmaW2);
                m00 += weight;
                mu20 += weight * dx * dx;
                mu11 += weight * dx * dy;
                mu02 += weight * dy * dy;
            }
        }

        if (m00 <= 0.0) {
            momentResultsBuffer[starIndex] =
                MomentResults{0.0, 0.0, 0.0, 0.0, 0.0, 0.0, maxPixelValue, sigmaW};
            return;
        }

        mu20 /= m00;
        mu11 /= m00;
        mu02 /= m00;

        // Adapt the window to the star for the second (final) iteration:
        // recover the window-corrected star sigma, then set the window to 1.5× that.
        if (iter == 0) {
            float measuredVariance = 0.5 * (mu20 + mu02);
            float windowVariance = sigmaW * sigmaW;
            float inverseDiff = 1.0 / max(measuredVariance, 1e-6) - 1.0 / windowVariance;
            float starVariance = (inverseDiff > 1e-6) ? 1.0 / inverseDiff : windowVariance;
            float starSigma = sqrt(max(starVariance, 0.25));
            sigmaW = clamp(1.5 * starSigma, 1.5, float(halfSize) / 2.0);
        }
    }

    // Store results; m10/m01 encode the refined centroid so the host's
    // centroid = m10/m00 computation keeps working unchanged.
    momentResultsBuffer[starIndex] =
        MomentResults{m00, cx * m00, cy * m00, mu20, mu11, mu02, maxPixelValue, sigmaW};
}

