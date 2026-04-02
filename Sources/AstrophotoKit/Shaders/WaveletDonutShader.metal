#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Kernel: subtract_textures
//
// Computes the Difference of Gaussians (DoG) by subtracting two blurred
// textures pixel-wise: out = texA - texB.
//
// Used by WaveletDonutProcessor to build a DoG response image at each scale.
// Both inputs are r32Float; negative values are valid (troughs, not peaks).
//
// Textures:
//   texture(0) — inner-blurred image (smaller sigma, read)
//   texture(1) — outer-blurred image (larger sigma, read)
//   texture(2) — DoG output (r32Float, write)
// ---------------------------------------------------------------------------
kernel void subtract_textures(
    texture2d<float, access::read>  texA   [[texture(0)]],
    texture2d<float, access::read>  texB   [[texture(1)]],
    texture2d<float, access::write> texOut [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= texOut.get_width() || gid.y >= texOut.get_height()) { return; }
    float dog = texA.read(gid).r - texB.read(gid).r;
    texOut.write(float4(dog, 0.0, 0.0, 1.0), gid);
}
