#include <metal_stdlib>
using namespace metal;

/// Compute shader for background subtraction
/// Subtracts a constant background level from each pixel and clamps to zero
/// Optimized for grayscale textures (r32Float) - works on R channel only
kernel void background_subtract(texture2d<float> inputTexture [[texture(0)]],
                                  texture2d<float, access::write> outputTexture [[texture(1)]],
                                  constant float& backgroundLevel [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // Read input pixel (grayscale texture - only R channel has data)
    float value = inputTexture.read(gid).r;
    
    // Subtract background and clamp to zero
    float result = max(0.0, value - backgroundLevel);
    
    // Write output (grayscale - only R channel is used)
    // Using float4(result) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(result), gid);
}

/// Compute shader to create a uniform background texture
/// Fills the entire texture with a constant background level
/// Optimized for grayscale textures (r32Float) - only R channel is used
kernel void background_fill(texture2d<float, access::write> outputTexture [[texture(0)]],
                          constant float& backgroundLevel [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // Write uniform background level (grayscale - only R channel is used)
    // Using float4(backgroundLevel) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(backgroundLevel), gid);
}

