#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

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

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                                   constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;
    // Apply aspect ratio correction and zoom/pan transform
    // First apply aspect ratio to keep pixels square
    float2 aspectCorrected = in.position * uniforms.aspectRatio;
    // Then apply zoom and pan
    float2 scaledPosition = aspectCorrected * uniforms.scale + uniforms.offset;
    out.position = float4(scaledPosition, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                                   texture2d<float> imageTexture [[texture(0)]],
                                   constant Uniforms& uniforms [[buffer(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = imageTexture.sample(textureSampler, in.texCoord);
    
    // Use the isGrayscale flag to determine how to process the texture
    if (uniforms.isGrayscale > 0.5) {
        // Grayscale texture (r32Float) - use R channel and convert to RGB for display
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
        
        // Convert grayscale to RGB for display (R=G=B for proper grayscale display)
        return float4(value, value, value, 1.0);
    } else {
        // RGB texture (rgba32Float) - may have color overlays (e.g., red ellipses)
        // Check if this pixel has actual color information (R, G, B are different)
        float colorDifference = abs(color.r - color.g) + abs(color.r - color.b) + abs(color.g - color.b);
        bool isColorPixel = colorDifference > 0.01; // Threshold for color detection
        
        if (isColorPixel) {
            // Color pixel (e.g., red ellipse overlay) - preserve color, apply black/white point to luminance
            // Calculate luminance
            float luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
            
            // Apply black/white point to luminance
            float range = uniforms.whitePoint - uniforms.blackPoint;
            float adjustedLuminance;
            if (range > 0.0) {
                adjustedLuminance = (luminance - uniforms.blackPoint) / range;
            } else {
                adjustedLuminance = luminance >= uniforms.whitePoint ? 1.0 : 0.0;
            }
            adjustedLuminance = clamp(adjustedLuminance, 0.0, 1.0);
            
            // Preserve color ratios but scale by adjusted luminance
            if (luminance > 0.001) {
                float scale = adjustedLuminance / luminance;
                float3 rgb = color.rgb * scale;
                rgb = clamp(rgb, 0.0, 1.0);
                return float4(rgb, 1.0);
            } else {
                // Very dark pixel - return as-is to preserve color
                return float4(color.rgb, 1.0);
            }
        } else {
            // Grayscale pixel in RGB texture (R=G=B) - convert to RGB for display
            float value = color.r;
            float range = uniforms.whitePoint - uniforms.blackPoint;
            if (range > 0.0) {
                value = (value - uniforms.blackPoint) / range;
            } else {
                value = value >= uniforms.whitePoint ? 1.0 : 0.0;
            }
            value = clamp(value, 0.0, 1.0);
            return float4(value, value, value, 1.0);
        }
    }
}
