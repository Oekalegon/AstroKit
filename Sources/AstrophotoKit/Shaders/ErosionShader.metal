#include <metal_stdlib>
using namespace metal;

/// Compute shader for binary erosion
/// Erosion shrinks objects by removing pixels from boundaries
/// A pixel is set to 1 only if ALL pixels in the structuring element are 1
/// Optimized for grayscale textures (r32Float) - works on R channel only
kernel void binary_erosion(texture2d<float> inputTexture [[texture(0)]],
                           texture2d<float, access::write> outputTexture [[texture(1)]],
                           constant int& kernelSize [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    int width = int(inputTexture.get_width());
    int height = int(inputTexture.get_height());
    int halfKernel = kernelSize / 2;
    
    // Calculate kernel bounds
    int startX = max(0, int(gid.x) - halfKernel);
    int endX = min(width - 1, int(gid.x) + halfKernel);
    int startY = max(0, int(gid.y) - halfKernel);
    int endY = min(height - 1, int(gid.y) + halfKernel);
    
    // Erosion: pixel is 1 only if ALL pixels in kernel are 1
    float result = 1.0;
    
    for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
            float4 pixel = inputTexture.read(uint2(x, y));
            // If any pixel in the kernel is 0, result is 0
            if (pixel.r < 0.5) {
                result = 0.0;
                // Early exit optimization
                x = endX + 1;
                y = endY + 1;
                break;
            }
        }
    }
    
    // Write result (grayscale - only R channel is used)
    // Using float4(result) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(result), gid);
}

/// Compute shader for grayscale erosion
/// Works on continuous values, takes the minimum value in the kernel
/// Optimized for grayscale textures (r32Float) - works on R channel only
kernel void grayscale_erosion(texture2d<float> inputTexture [[texture(0)]],
                              texture2d<float, access::write> outputTexture [[texture(1)]],
                              constant int& kernelSize [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    int width = int(inputTexture.get_width());
    int height = int(inputTexture.get_height());
    int halfKernel = kernelSize / 2;
    
    // Calculate kernel bounds
    int startX = max(0, int(gid.x) - halfKernel);
    int endX = min(width - 1, int(gid.x) + halfKernel);
    int startY = max(0, int(gid.y) - halfKernel);
    int endY = min(height - 1, int(gid.y) + halfKernel);
    
    // Erosion: take minimum value in kernel
    float minValue = 1.0;
    
    for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
            float4 pixel = inputTexture.read(uint2(x, y));
            minValue = min(minValue, pixel.r);
        }
    }
    
    // Write result (grayscale - only R channel is used)
    // Using float4(minValue) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(minValue), gid);
}

