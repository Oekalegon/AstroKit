#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Parameters shared by the hough_vote kernel
// ---------------------------------------------------------------------------
struct HoughParams {
    int   rMin;            // Minimum circle radius (inclusive)
    int   rMax;            // Maximum circle radius (inclusive)
    int   width;           // Crop texture width
    int   height;          // Crop texture height
    float edgeThreshold;   // Sobel magnitude threshold to consider a pixel as an edge
};

// ---------------------------------------------------------------------------
// Kernel 1: sobel_gradient
//
// Computes the Sobel gradient magnitude and direction for each pixel in the
// input greyscale texture and writes the results to two separate textures.
//
// Textures:
//   texture(0) — input greyscale (read)
//   texture(1) — gradient magnitude output (r32Float, write)
//   texture(2) — gradient angle output    (r32Float, write), range (-π, π]
// ---------------------------------------------------------------------------
kernel void sobel_gradient(
    texture2d<float, access::read>  inputTex   [[texture(0)]],
    texture2d<float, access::write> gradMagTex [[texture(1)]],
    texture2d<float, access::write> gradAngTex [[texture(2)]],
    uint2 pos [[thread_position_in_grid]]
) {
    const int W = int(inputTex.get_width());
    const int H = int(inputTex.get_height());

    if (int(pos.x) >= W || int(pos.y) >= H) { return; }

    // 3x3 Sobel kernels
    // Clamp neighbours to image boundary
    auto sample = [&](int dx, int dy) -> float {
        int nx = clamp(int(pos.x) + dx, 0, W - 1);
        int ny = clamp(int(pos.y) + dy, 0, H - 1);
        return inputTex.read(uint2(nx, ny)).r;
    };

    // Standard Sobel:
    //   Gx = right column − left column  (gradient in X, detects vertical edges)
    //   Gy = bottom row − top row        (gradient in Y, positive = brighter below)
    float gx =  sample( 1, -1) + 2.0 * sample( 1,  0) + sample( 1,  1)
              - sample(-1, -1) - 2.0 * sample(-1,  0) - sample(-1,  1);

    float gy =  sample(-1,  1) + 2.0 * sample( 0,  1) + sample( 1,  1)
              - sample(-1, -1) - 2.0 * sample( 0, -1) - sample( 1, -1);

    float magnitude = sqrt(gx * gx + gy * gy);
    float angle     = atan2(gy, gx);

    gradMagTex.write(float4(magnitude, 0, 0, 1), pos);
    gradAngTex.write(float4(angle,     0, 0, 1), pos);
}

// ---------------------------------------------------------------------------
// Kernel 2: hough_vote
//
// Gradient-directed Hough circle accumulation.  For each edge pixel (magnitude
// above threshold) and each candidate radius r in [rMin, rMax], the kernel
// votes for two candidate circle centres located at distance r along the
// gradient direction (both forward and backward).
//
// The accumulator is a flat 1-D buffer of atomic_int values with layout:
//   index = (r - rMin) * width * height + cy * width + cx
//
// Textures:
//   texture(0) — gradient magnitude (r32Float, read)
//   texture(1) — gradient angle     (r32Float, read)
//
// Buffers:
//   buffer(0) — atomic_int accumulator [(rMax-rMin+1) * width * height]
//   buffer(1) — HoughParams (constant)
// ---------------------------------------------------------------------------
kernel void hough_vote(
    texture2d<float, access::read> gradMagTex  [[texture(0)]],
    texture2d<float, access::read> gradAngTex  [[texture(1)]],
    device atomic_int*             accumulator [[buffer(0)]],
    constant HoughParams&          params      [[buffer(1)]],
    uint2 pos [[thread_position_in_grid]]
) {
    if (int(pos.x) >= params.width || int(pos.y) >= params.height) { return; }

    float mag = gradMagTex.read(pos).r;
    if (mag < params.edgeThreshold) { return; }

    float angle = gradAngTex.read(pos).r;
    float cosA  = cos(angle);
    float sinA  = sin(angle);

    int px = int(pos.x);
    int py = int(pos.y);

    for (int r = params.rMin; r <= params.rMax; r++) {
        float fr = float(r);
        int rIdx = r - params.rMin;

        // Vote in both gradient directions
        for (int dir = -1; dir <= 1; dir += 2) {
            int cx = px + int(round(fr * cosA * float(dir)));
            int cy = py + int(round(fr * sinA * float(dir)));

            if (cx < 0 || cx >= params.width || cy < 0 || cy >= params.height) { continue; }

            int accIdx = rIdx * params.width * params.height + cy * params.width + cx;
            atomic_fetch_add_explicit(&accumulator[accIdx], 1, memory_order_relaxed);
        }
    }
}
