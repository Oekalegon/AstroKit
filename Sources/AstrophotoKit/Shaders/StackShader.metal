#include <metal_stdlib>
using namespace metal;

// Maximum frames per stack — determines thread-local array size (4 bytes × N per thread).
// Raise in powers of 2 if needed; 128 is sufficient for virtually all amateur stacks.
#define STACK_MAX_FRAMES 128

struct StackParams {
    uint  nFrames;
    uint  stackMode;   // 0=average 1=sum 2=median 3=max_pixel 4=min_pixel
    uint  rejMode;     // 0=none 1=sigma_clip 2=winsorized
    float rejLow;
    float rejHigh;
};

struct FrameNorm {
    float mulFactor;
    float addOffset;
};

// Insertion sort — O(N²) but N ≤ 128 so negligible per pixel
static inline void insertion_sort(thread float* arr, uint n) {
    for (uint i = 1u; i < n; i++) {
        float key = arr[i];
        int j = (int)i - 1;
        while (j >= 0 && arr[j] > key) {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}

kernel void stack_frames(
    texture2d_array<float, access::read>  frames     [[texture(0)]],
    texture2d<float,       access::write> output     [[texture(1)]],
    constant StackParams                 &params     [[buffer(0)]],
    constant FrameNorm                   *normParams [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

    const uint n = min(params.nFrames, (uint)STACK_MAX_FRAMES);

    // Load and normalise — skip frames whose warp returned the out-of-bounds sentinel (-1.0).
    float vals[STACK_MAX_FRAMES];
    uint count = 0u;
    for (uint i = 0u; i < n; i++) {
        float v = frames.read(gid, i).r;
        if (v < 0.0f) continue;   // sentinel: this frame doesn't cover this pixel
        vals[count++] = v * normParams[i].mulFactor + normParams[i].addOffset;
    }

    // Pixel rejection
    if (params.rejMode != 0u && count > 2u) {

        if (params.rejMode == 1u) {
            // Sigma-clip with NMAD estimator (up to 3 iterations).
            // NMAD = MAD / 0.6745 estimates σ using the median absolute deviation,
            // which is unaffected by the outliers it is trying to reject.  This is
            // critical for hot pixels: with N frames where 1 has a hot pixel and
            // N-1 have sky, the sample std is dominated by the outlier and places
            // it within 3σ — but NMAD correctly measures sky noise and places the
            // hot pixel at ≫ 3σ.
            float devs[STACK_MAX_FRAMES];
            for (uint iter = 0u; iter < 3u && count > 2u; iter++) {
                insertion_sort(vals, count);
                uint m = count / 2u;
                float med = (count % 2u == 0u)
                    ? (vals[m - 1u] + vals[m]) * 0.5f : vals[m];
                for (uint i = 0u; i < count; i++) devs[i] = fabs(vals[i] - med);
                insertion_sort(devs, count);
                float mad = (count % 2u == 0u)
                    ? (devs[m - 1u] + devs[m]) * 0.5f : devs[m];
                float sigma = mad / 0.6745f;
                if (sigma < 1e-9f) break;

                const float lo = med - params.rejLow  * sigma;
                const float hi = med + params.rejHigh * sigma;

                // vals is sorted; trim from both ends
                uint loI = 0u;
                while (loI < count && vals[loI] < lo) loI++;
                uint hiI = count;
                while (hiI > loI && vals[hiI - 1u] > hi) hiI--;
                uint nc = hiI - loI;
                if (nc == 0u || nc == count) break;
                for (uint i = 0u; i < nc; i++) vals[i] = vals[loI + i];
                count = nc;
            }

        } else {
            // Winsorized sigma-clip (mode 2) — 3 iterations, mean/std based.
            // Winsorized clamps extreme values before re-estimating σ, making it
            // more tolerant of moderate outliers than plain sigma-clip.
            for (uint iter = 0u; iter < 3u && count > 2u; iter++) {
                float sum = 0.0f;
                for (uint i = 0u; i < count; i++) sum += vals[i];
                float mean = sum / float(count);
                float var = 0.0f;
                for (uint i = 0u; i < count; i++) {
                    float d = vals[i] - mean;
                    var += d * d;
                }
                float sigma = sqrt(var / float(count));
                if (sigma < 1e-9f) break;

                const float lo = mean - params.rejLow  * sigma;
                const float hi = mean + params.rejHigh * sigma;

                float wsum = 0.0f;
                for (uint i = 0u; i < count; i++) wsum += clamp(vals[i], lo, hi);
                float wmean = wsum / float(count);
                float wvar  = 0.0f;
                for (uint i = 0u; i < count; i++) {
                    float w = clamp(vals[i], lo, hi) - wmean;
                    wvar += w * w;
                }
                float wsigma = sqrt(wvar / float(count));
                if (wsigma < 1e-9f) break;
                const float wlo = wmean - params.rejLow  * wsigma;
                const float whi = wmean + params.rejHigh * wsigma;
                uint nc = 0u;
                for (uint i = 0u; i < count; i++) {
                    if (vals[i] >= wlo && vals[i] <= whi) vals[nc++] = vals[i];
                }
                if (nc == 0u || nc == count) break;
                count = nc;
            }
        }
    }

    // Combine
    float result = 0.0f;
    switch (params.stackMode) {
        case 1u: { // sum
            for (uint i = 0u; i < count; i++) result += vals[i];
            break;
        }
        case 2u: { // median
            insertion_sort(vals, count);
            uint m = count / 2u;
            result = (count % 2u == 0u) ? (vals[m - 1u] + vals[m]) * 0.5f : vals[m];
            break;
        }
        case 3u: { // max_pixel
            result = vals[0];
            for (uint i = 1u; i < count; i++) if (vals[i] > result) result = vals[i];
            break;
        }
        case 4u: { // min_pixel
            result = vals[0];
            for (uint i = 1u; i < count; i++) if (vals[i] < result) result = vals[i];
            break;
        }
        default: { // 0 = average (and unknown)
            for (uint i = 0u; i < count; i++) result += vals[i];
            result /= float(count);
            break;
        }
    }

    output.write(float4(result, 0.0f, 0.0f, 0.0f), gid);
}
