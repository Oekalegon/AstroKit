#include <metal_stdlib>
using namespace metal;

/// Affine warp kernel — applies a similarity transform to align a source frame into
/// the reference coordinate system using Lanczos-2 interpolation.
///
/// params.xy = (a, b) where a = scale*cos(θ), b = scale*sin(θ)
/// params.zw = (tx, ty) — translation from the registration table
///
/// For each output pixel (ox, oy) in reference space the corresponding source
/// pixel in the target frame is:
///   srcX = a * ox − b * oy + tx
///   srcY = b * ox + a * oy + ty

// Lanczos-2 kernel: sinc(x) * sinc(x/2) for |x| < 2, 0 otherwise.
// Weights are normalised after accumulation so the kernel sums to 1 even at borders.
static inline float lanczos2(float x) {
    if (x < -2.0f || x > 2.0f) return 0.0f;
    if (x == 0.0f) return 1.0f;
    const float px = M_PI_F * x;
    return 2.0f * sin(px) * sin(px * 0.5f) / (px * px);
}

kernel void affine_warp(
    texture2d<float, access::read>  inputTexture  [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float4                &params        [[buffer(0)]],
    uint2                           gid            [[thread_position_in_grid]]
) {
    const int outW = (int)outputTexture.get_width();
    const int outH = (int)outputTexture.get_height();
    if ((int)gid.x >= outW || (int)gid.y >= outH) { return; }

    const int inW = (int)inputTexture.get_width();
    const int inH = (int)inputTexture.get_height();

    const float a  = params.x;
    const float b  = params.y;
    const float tx = params.z;
    const float ty = params.w;

    const float ox = (float)gid.x;
    const float oy = (float)gid.y;

    const float srcX = a * ox - b * oy + tx;
    const float srcY = b * ox + a * oy + ty;

    // Lanczos-2 uses a 4×4 neighbourhood centred on the integer pixel below srcX/srcY.
    const int cx = (int)floor(srcX);
    const int cy = (int)floor(srcY);

    // If the entire 4×4 support region is outside the source frame write the
    // out-of-bounds sentinel so the stack kernel can exclude this frame at this pixel.
    if (cx + 2 < 0 || cx - 1 >= inW || cy + 2 < 0 || cy - 1 >= inH) {
        outputTexture.write(float4(-1.0f, 0.0f, 0.0f, 0.0f), gid);
        return;
    }

    // Precompute 1-D Lanczos weights for x and y axes.
    float wx[4], wy[4];
    for (int k = 0; k < 4; k++) {
        wx[k] = lanczos2(srcX - (float)(cx - 1 + k));
        wy[k] = lanczos2(srcY - (float)(cy - 1 + k));
    }

    // 2-D separable convolution with border clamping.
    // Out-of-bounds taps are excluded; their weights are redistributed via renormalisation.
    float value  = 0.0f;
    float wsum   = 0.0f;
    for (int jj = 0; jj < 4; jj++) {
        const int sy = cy - 1 + jj;
        if (sy < 0 || sy >= inH) continue;
        for (int ii = 0; ii < 4; ii++) {
            const int sx = cx - 1 + ii;
            if (sx < 0 || sx >= inW) continue;
            const float w = wx[ii] * wy[jj];
            value += w * inputTexture.read(uint2(sx, sy)).r;
            wsum  += w;
        }
    }

    // Renormalise so border pixels aren't darkened.  If wsum ≈ 0 (degenerate case)
    // fall back to the sentinel so the stacker ignores this sample entirely.
    if (wsum < 1e-6f) {
        outputTexture.write(float4(-1.0f, 0.0f, 0.0f, 0.0f), gid);
        return;
    }

    outputTexture.write(float4(value / wsum, 0.0f, 0.0f, 0.0f), gid);
}
