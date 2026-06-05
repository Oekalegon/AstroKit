#include <metal_stdlib>
using namespace metal;

/// Structure to hold star information for FWHM calculation
struct StarInfo {
    float centroidX;
    float centroidY;
    int regionSize;  // Region size for this star (based on major/minor axis)
};

/// Structure to hold moment results for a star
struct MomentResults {
    float m00;  // Zeroth moment (total weight)
    float m10;  // First moment X
    float m01;  // First moment Y
    float mu20; // Second central moment X (variance)
    float mu11; // Covariance
    float mu02; // Second central moment Y (variance)
    float maxPixelValue; // Maximum pixel value in the region (for saturation detection)
};

/// Compute shader to calculate weighted image moments for a single star
/// Each thread processes one star, reading a region around the star's centroid
/// and calculating weighted moments using pixel intensities as weights
kernel void calculate_star_moments(texture2d<float> inputTexture [[texture(0)]],
                                    device StarInfo* starInfoBuffer [[buffer(0)]],
                                    device MomentResults* momentResultsBuffer [[buffer(1)]],
                                    uint starIndex [[thread_position_in_grid]]) {
    // Get star information
    StarInfo star = starInfoBuffer[starIndex];
    int centerX = int(round(star.centroidX));
    int centerY = int(round(star.centroidY));
    
    // Use per-star region size
    int regionSize = star.regionSize;
    int halfSize = regionSize / 2;
    int textureWidth = int(inputTexture.get_width());
    int textureHeight = int(inputTexture.get_height());
    
    // Calculate region bounds
    int x0 = max(0, centerX - halfSize);
    int y0 = max(0, centerY - halfSize);
    int x1 = min(textureWidth, centerX + halfSize);
    int y1 = min(textureHeight, centerY + halfSize);
    
    int regionWidth = x1 - x0;
    int regionHeight = y1 - y0;
    
    // Initialize moments
    float m00 = 0.0;
    float m10 = 0.0;
    float m01 = 0.0;
    float maxPixelValue = 0.0;
    
    // Calculate first pass: zeroth and first moments, and track maximum pixel value
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            uint2 coord = uint2(x, y);
            float4 pixel = inputTexture.read(coord);
            float weight = pixel.r;  // Use red channel (grayscale) or could use luminance
            
            // Track maximum pixel value for saturation detection
            maxPixelValue = max(maxPixelValue, weight);
            
            float pixelX = float(x);
            float pixelY = float(y);
            
            m00 += weight;
            m10 += weight * pixelX;
            m01 += weight * pixelY;
        }
    }
    
    // Check if we have valid data
    if (m00 <= 0.0 || regionWidth <= 0 || regionHeight <= 0) {
        momentResultsBuffer[starIndex] = MomentResults{0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
        return;
    }
    
    // Calculate centroid
    float centroidX = m10 / m00;
    float centroidY = m01 / m00;
    
    // Calculate second central moments (variance)
    float mu20 = 0.0;
    float mu11 = 0.0;
    float mu02 = 0.0;
    
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            uint2 coord = uint2(x, y);
            float4 pixel = inputTexture.read(coord);
            float weight = pixel.r;
            
            float pixelX = float(x);
            float pixelY = float(y);
            
            float deltaX = pixelX - centroidX;
            float deltaY = pixelY - centroidY;
            
            mu20 += weight * deltaX * deltaX;
            mu11 += weight * deltaX * deltaY;
            mu02 += weight * deltaY * deltaY;
        }
    }
    
    // Normalize by total weight
    mu20 /= m00;
    mu11 /= m00;
    mu02 /= m00;
    
    // Store results (including maximum pixel value for saturation detection)
    momentResultsBuffer[starIndex] = MomentResults{m00, m10, m01, mu20, mu11, mu02, maxPixelValue};
}

