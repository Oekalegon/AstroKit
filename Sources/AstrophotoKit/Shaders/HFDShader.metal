#include <metal_stdlib>
using namespace metal;

/// Information about a single star or donut for HFD calculation
struct HFDInfo {
    float centroidX;
    float centroidY;
    int regionSize;   // Full side length of the sampling region
    int isDonut;      // 0 = focused star, 1 = out-of-focus donut ring
    float innerR;     // Inner radius to skip when isDonut == 1 (secondary mirror shadow)
};

/// Results of HFD calculation for one star / donut
struct HFDResults {
    float sumDistIntensity; // Σ(d_i * I_i)
    float sumIntensity;     // Σ(I_i)
    float hfd;              // = 2 * sumDistIntensity / sumIntensity
    float centroidX;        // Refined centroid X
    float centroidY;        // Refined centroid Y
    float maxPixelValue;    // For saturation detection
};

/// Compute shader to calculate Half-Flux Diameter (HFD) for a single star or donut.
/// Each thread processes one star/donut.
///
/// For focused stars: reads a square region around the centroid, computes
///   HFD = 2 * Σ(dist_i * I_i) / Σ(I_i)
/// For donut stars (reflector out-of-focus): same region but skips the central
///   dark hole (dist < innerR * 0.9) corresponding to the secondary mirror shadow.
///
/// Two-pass algorithm (same structure as calculate_star_moments in FWHMShader.metal):
///   Pass 1: compute intensity-weighted centroid
///   Pass 2: compute HFD from centroid-relative distances
kernel void calculate_hfd(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device const HFDInfo*          hfdInfoBuffer   [[buffer(0)]],
    device       HFDResults*       hfdResultsBuffer [[buffer(1)]],
    uint starIndex [[thread_position_in_grid]]
) {
    HFDInfo star = hfdInfoBuffer[starIndex];

    int centerX   = int(round(star.centroidX));
    int centerY   = int(round(star.centroidY));
    int halfSize  = star.regionSize / 2;
    int texWidth  = int(inputTexture.get_width());
    int texHeight = int(inputTexture.get_height());

    int x0 = max(0, centerX - halfSize);
    int y0 = max(0, centerY - halfSize);
    int x1 = min(texWidth,  centerX + halfSize);
    int y1 = min(texHeight, centerY + halfSize);

    if (x1 <= x0 || y1 <= y0) {
        hfdResultsBuffer[starIndex] = HFDResults{0.0, 0.0, 0.0, star.centroidX, star.centroidY, 0.0};
        return;
    }

    // ---- Pass 1: intensity-weighted centroid + max pixel value ----
    float m00 = 0.0;
    float m10 = 0.0;
    float m01 = 0.0;
    float maxVal = 0.0;

    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float w = inputTexture.read(uint2(x, y)).r;
            maxVal = max(maxVal, w);
            m00 += w;
            m10 += w * float(x);
            m01 += w * float(y);
        }
    }

    if (m00 <= 0.0) {
        hfdResultsBuffer[starIndex] = HFDResults{0.0, 0.0, 0.0, star.centroidX, star.centroidY, maxVal};
        return;
    }

    float cx = m10 / m00;
    float cy = m01 / m00;

    // ---- Pass 2: HFD accumulation ----
    float sumDistI = 0.0;
    float sumI     = 0.0;
    float innerSkipR = star.innerR * 0.9;

    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float dx   = float(x) - cx;
            float dy   = float(y) - cy;
            float dist = sqrt(dx * dx + dy * dy);

            // For donuts, skip the dark central hole
            if (star.isDonut && dist < innerSkipR) {
                continue;
            }

            float w = inputTexture.read(uint2(x, y)).r;
            sumDistI += dist * w;
            sumI     += w;
        }
    }

    float hfd = (sumI > 0.0) ? (2.0 * sumDistI / sumI) : 0.0;

    hfdResultsBuffer[starIndex] = HFDResults{sumDistI, sumI, hfd, cx, cy, maxVal};
}
