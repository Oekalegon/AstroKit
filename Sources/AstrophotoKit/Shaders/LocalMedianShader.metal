#include <metal_stdlib>
using namespace metal;

/// Compute shader for local median estimation
/// For each pixel, samples a local window and calculates the median value
/// Uses a histogram-based approach for efficiency
kernel void local_median(texture2d<float> inputTexture [[texture(0)]],
                         texture2d<float, access::write> outputTexture [[texture(1)]],
                         constant int& windowSize [[buffer(0)]],
                         constant float& imageMinValue [[buffer(1)]],
                         constant float& imageMaxValue [[buffer(2)]],
                         constant int& numBins [[buffer(3)]],
                         constant int& sampleStepThreshold [[buffer(4)]],
                         uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    int width = int(inputTexture.get_width());
    int height = int(inputTexture.get_height());
    int halfWindow = windowSize / 2;
    
    // Calculate window bounds
    int startX = max(0, int(gid.x) - halfWindow);
    int endX = min(width - 1, int(gid.x) + halfWindow);
    int startY = max(0, int(gid.y) - halfWindow);
    int endY = min(height - 1, int(gid.y) + halfWindow);
    
    // Use a histogram to find the median
    // Number of bins is configurable (default: 128 for good performance/accuracy balance)
    // Use fixed maximum size (256) to support variable numBins
    const int maxBins = 256;
    uint histogram[maxBins];
    
    // Initialize histogram (only the bins we'll use)
    int actualBins = min(numBins, maxBins);
    for (int i = 0; i < actualBins; i++) {
        histogram[i] = 0;
    }
    
    // Sample pixels in the window and build histogram
    // Adaptive sampling: for windows larger than threshold, sample every 2nd pixel
    int pixelCount = 0;
    float imageRange = imageMaxValue - imageMinValue;
    int sampleStep = (windowSize > sampleStepThreshold) ? 2 : 1;
    
    for (int y = startY; y <= endY; y += sampleStep) {
        for (int x = startX; x <= endX; x += sampleStep) {
            float4 pixel = inputTexture.read(uint2(x, y));
            float normalizedValue = pixel.r;
            
            // Convert normalized value to image pixel value
            float pixelValue = imageMinValue + normalizedValue * imageRange;
            
            // Map to histogram bin
            float normalizedForBin = (pixelValue - imageMinValue) / imageRange;
            normalizedForBin = clamp(normalizedForBin, 0.0f, 1.0f);
            
            int binIndex = min(int(normalizedForBin * float(actualBins)), actualBins - 1);
            histogram[binIndex]++;
            pixelCount++;
        }
    }
    
    // Adjust target count if we sampled (need to account for sampling)
    // When sampling every 2nd pixel, we effectively have ~4x fewer samples
    // but the median position relative to the sampled set is still correct
    
    // Find median from histogram
    int targetCount = pixelCount / 2; // Median is at 50% of pixels
    int cumulativeCount = 0;
    int medianBin = 0;
    
    for (int i = 0; i < actualBins; i++) {
        cumulativeCount += histogram[i];
        if (cumulativeCount >= targetCount) {
            medianBin = i;
            break;
        }
    }
    
    // Convert median bin back to pixel value
    float binCenter = (float(medianBin) + 0.5) / float(actualBins);
    float medianValue = imageMinValue + binCenter * imageRange;
    
    // Normalize back to [0, 1] range for output
    float normalizedMedian = (medianValue - imageMinValue) / imageRange;
    normalizedMedian = clamp(normalizedMedian, 0.0f, 1.0f);
    
    // Write median value
    outputTexture.write(float4(normalizedMedian), gid);
}

/// Compute shader for local median background subtraction
/// Subtracts the local median background from each pixel
kernel void local_median_subtract(texture2d<float> inputTexture [[texture(0)]],
                                   texture2d<float> backgroundTexture [[texture(1)]],
                                   texture2d<float, access::write> outputTexture [[texture(2)]],
                                   constant float& imageMinValue [[buffer(0)]],
                                   constant float& imageMaxValue [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    // Read input and background pixels
    float4 inputPixel = inputTexture.read(gid);
    float4 backgroundPixel = backgroundTexture.read(gid);
    
    // Convert normalized values to image pixel values
    float imageRange = imageMaxValue - imageMinValue;
    float inputValue = imageMinValue + inputPixel.r * imageRange;
    float backgroundValue = imageMinValue + backgroundPixel.r * imageRange;
    
    // Subtract background and clamp to zero
    float resultValue = max(0.0f, inputValue - backgroundValue);
    
    // Normalize back to [0, 1] range
    float normalizedResult = (resultValue - imageMinValue) / imageRange;
    normalizedResult = clamp(normalizedResult, 0.0f, 1.0f);
    
    // Write output
    outputTexture.write(float4(normalizedResult), gid);
}

