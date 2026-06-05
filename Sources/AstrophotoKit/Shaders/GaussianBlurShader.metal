#include <metal_stdlib>
using namespace metal;

/// Compute shader for Gaussian blur
/// This shader performs a separable Gaussian blur in two passes:
/// 1. Horizontal pass: blurs along the X-axis
/// 2. Vertical pass: blurs along the Y-axis
/// Optimized for grayscale textures (r32Float) - works on R channel only
/// 
/// Parameters:
/// - radius: Blur radius in pixels (sigma = radius / 2.0)
/// - direction: 0 for horizontal, 1 for vertical

// Calculate Gaussian weight for a given offset
inline float gaussianWeight(float offset, float sigma) {
    return exp(-(offset * offset) / (2.0 * sigma * sigma));
}

// Horizontal blur pass
kernel void gaussian_blur_horizontal(texture2d<float> inputTexture [[texture(0)]],
                                          texture2d<float, access::write> outputTexture [[texture(1)]],
                                          constant float& radius [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float sigma = max(radius / 2.0, 0.5);
    int kernelRadius = int(ceil(radius * 2.0)); // Use 2*sigma for kernel size
    
    // Optimized for grayscale textures (r32Float) - work with R channel only
    float sum = 0.0;
    float weightSum = 0.0;
    
    // Sample pixels along horizontal line
    for (int x = -kernelRadius; x <= kernelRadius; x++) {
        int sampleX = int(gid.x) + x;
        
        // Clamp to texture bounds
        sampleX = clamp(sampleX, 0, int(inputTexture.get_width()) - 1);
        
        float offset = float(x);
        float weight = gaussianWeight(offset, sigma);
        
        // Read grayscale value (only R channel has data)
        float sample = inputTexture.read(uint2(sampleX, gid.y)).r;
        sum += sample * weight;
        weightSum += weight;
    }
    
    // Normalize by total weight
    float result = (weightSum > 0.0) ? (sum / weightSum) : 0.0;
    
    // Write output (grayscale - only R channel is used)
    // Using float4(result) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(result), gid);
}

// Vertical blur pass
kernel void gaussian_blur_vertical(texture2d<float> inputTexture [[texture(0)]],
                                        texture2d<float, access::write> outputTexture [[texture(1)]],
                                        constant float& radius [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float sigma = max(radius / 2.0, 0.5);
    int kernelRadius = int(ceil(radius * 2.0)); // Use 2*sigma for kernel size
    
    // Optimized for grayscale textures (r32Float) - work with R channel only
    float sum = 0.0;
    float weightSum = 0.0;
    
    // Sample pixels along vertical line
    for (int y = -kernelRadius; y <= kernelRadius; y++) {
        int sampleY = int(gid.y) + y;
        
        // Clamp to texture bounds
        sampleY = clamp(sampleY, 0, int(inputTexture.get_height()) - 1);
        
        float offset = float(y);
        float weight = gaussianWeight(offset, sigma);
        
        // Read grayscale value (only R channel has data)
        float sample = inputTexture.read(uint2(gid.x, sampleY)).r;
        sum += sample * weight;
        weightSum += weight;
    }
    
    // Normalize by total weight
    float result = (weightSum > 0.0) ? (sum / weightSum) : 0.0;
    
    // Write output (grayscale - only R channel is used)
    // Using float4(result) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(result), gid);
}

