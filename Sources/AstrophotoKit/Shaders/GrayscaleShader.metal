#include <metal_stdlib>
using namespace metal;

/// Compute shader for converting RGB images to grayscale
/// If the input is RGB, extracts the Red channel to create grayscale
/// If the input is already grayscale (single channel or R=G=B), passes it through
kernel void grayscale(texture2d<float> inputTexture [[texture(0)]],
                      texture2d<float, access::write> outputTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Read input pixel
    float4 inputPixel = inputTexture.read(gid);

    // Extract grayscale value
    // For single-channel textures (r32Float), the value is in the red channel
    // For RGB textures, use the Red channel as requested
    // For already grayscale textures (where R=G=B), any channel works
    float grayscaleValue = inputPixel.r;

    // Write grayscale value to output
    // For single-channel output textures (r32Float), Metal will use the first component
    // Using float4(grayscaleValue) broadcasts the value, which is more efficient than explicit zeros
    outputTexture.write(float4(grayscaleValue), gid);
}

