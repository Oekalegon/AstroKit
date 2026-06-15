#include <metal_stdlib>
using namespace metal;

/// Compute shader for thresholding
/// Creates a binary mask where pixels >= threshold are set to 1.0, others to 0.0
/// Optimized for grayscale textures (r32Float) - works on R channel only
kernel void threshold(texture2d<float> inputTexture [[texture(0)]],
                      texture2d<float, access::write> outputTexture [[texture(1)]],
                      constant float& thresholdValue [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // Read input pixel (grayscale texture - only R channel has data)
    float value = inputTexture.read(gid).r;
    
    // Apply threshold: 1.0 if >= threshold, 0.0 otherwise
    float result = (value >= thresholdValue) ? 1.0 : 0.0;
    
    // Write output
    // Note: Metal's write() API requires float4, but the output texture is r32Float (grayscale),
    // so only the R component is actually stored. The G, B, A components are ignored.
    // Using float4(result) broadcasts the value, which is more efficient than explicit zeros.
    outputTexture.write(float4(result), gid);
}

