#include <metal_stdlib>
using namespace metal;

/// Compute shader for binary dilation
/// Dilation expands objects by adding pixels to boundaries
/// A pixel is set to 1 if ANY pixel in the structuring element is 1
/// Optimized for grayscale textures (r32Float) - works on R channel only
kernel void binary_dilation(texture2d<float> inputTexture [[texture(0)]],
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
    
    // Dilation: pixel is 1 if ANY pixel in kernel is 1
    float result = 0.0;
    
    for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
            float4 pixel = inputTexture.read(uint2(x, y));
            // If any pixel in the kernel is 1, result is 1
            if (pixel.r >= 0.5) {
                result = 1.0;
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

/// Compute shader for grayscale dilation
/// Works on continuous values, takes the maximum value in the kernel
/// Optimized for grayscale textures (r32Float) - works on R channel only
kernel void grayscale_dilation(texture2d<float> inputTexture [[texture(0)]],
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
    
    // Dilation: take maximum value in kernel
    float maxValue = 0.0;
    
    for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
            float4 pixel = inputTexture.read(uint2(x, y));
            maxValue = max(maxValue, pixel.r);
        }
    }
    
    // Write result (grayscale - only R channel is used)
    // Using float4(maxValue) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(maxValue), gid);
}

