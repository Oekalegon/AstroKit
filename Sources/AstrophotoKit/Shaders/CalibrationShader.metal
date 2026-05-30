#include <metal_stdlib>
using namespace metal;

// Pixel-wise subtraction of two r32Float frames.
// result = input - subtract, clamped to zero when clipToZero is true.
kernel void subtract_frames(
    texture2d<float>               inputTex    [[texture(0)]],
    texture2d<float>               subtractTex [[texture(1)]],
    texture2d<float, access::write> outputTex  [[texture(2)]],
    constant bool& clipToZero [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTex.get_width() || gid.y >= outputTex.get_height()) return;
    float a = inputTex.read(gid).r;
    float b = subtractTex.read(gid).r;
    float result = a - b;
    if (clipToZero && result < 0.0f) result = 0.0f;
    outputTex.write(float4(result, 0.0f, 0.0f, 1.0f), gid);
}

// Divides input_frame by a normalized version of divisor_frame (flat field correction).
// normalized divisor = divisor / divisorMean
// result = input / (divisor / divisorMean) = input * divisorMean / divisor
// When divisor is zero or near zero the input pixel is preserved unchanged.
kernel void divide_normalized_frame(
    texture2d<float>               inputTex   [[texture(0)]],
    texture2d<float>               divisorTex [[texture(1)]],
    texture2d<float, access::write> outputTex [[texture(2)]],
    constant float& divisorMean [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTex.get_width() || gid.y >= outputTex.get_height()) return;
    float a = inputTex.read(gid).r;
    float d = divisorTex.read(gid).r;
    float result = (d > 1e-9f) ? (a * divisorMean / d) : a;
    outputTex.write(float4(result, 0.0f, 0.0f, 1.0f), gid);
}
