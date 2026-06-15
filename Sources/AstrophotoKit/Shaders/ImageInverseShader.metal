#include <metal_stdlib>
using namespace metal;

// Vertex structures are shared with ImageShader.metal
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float2 scale;      // Zoom scale (x, y) - 8 bytes, offset 0
    float2 offset;     // Pan offset (x, y) - 8 bytes, offset 8
    float2 aspectRatio; // Aspect ratio correction (image aspect / view aspect) - 8 bytes, offset 16
    float _padding;     // Padding to align to 8-byte boundary - 4 bytes, offset 24
    float blackPoint;  // Black point (normalized 0-1) - 4 bytes, offset 28
    float whitePoint;  // White point (normalized 0-1) - 4 bytes, offset 32
    float isGrayscale; // 1.0 if texture is grayscale (r32Float), 0.0 if RGB (rgba32Float) - 4 bytes, offset 36
};

fragment float4 fragment_inverse(VertexOut in [[stage_in]],
                                     texture2d<float> imageTexture [[texture(0)]],
                                     constant Uniforms& uniforms [[buffer(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = imageTexture.sample(textureSampler, in.texCoord);
    
    // Apply black/white point adjustment
    float value = color.r;
    float range = uniforms.whitePoint - uniforms.blackPoint;
    if (range > 0.0) {
        // Remap from [blackPoint, whitePoint] to [0, 1]
        value = (value - uniforms.blackPoint) / range;
    } else {
        // If range is zero or negative, clamp everything
        value = value >= uniforms.whitePoint ? 1.0 : 0.0;
    }
    // Clamp to [0, 1]
    value = clamp(value, 0.0, 1.0);

    // Invert the grayscale value (1.0 - value)
    float inverted = 1.0 - value;
    // Convert inverted grayscale to RGB for display
    return float4(inverted, inverted, inverted, 1.0);
}

