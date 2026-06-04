#include <metal_stdlib>
using namespace metal;

/// Compute shader for calculating mean and standard deviation
/// Uses atomic operations to accumulate sum and sum of squares
kernel void calculate_mean_stddev(texture2d<float> inputTexture [[texture(0)]],
                                  device atomic_float* sumBuffer [[buffer(0)]],
                                  device atomic_float* sumSqBuffer [[buffer(1)]],
                                  constant float& imageMinValue [[buffer(2)]],
                                  constant float& imageMaxValue [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // Read pixel and convert to actual value
    float4 pixel = inputTexture.read(gid);
    float normalizedValue = pixel.r;
    float imageRange = imageMaxValue - imageMinValue;
    float pixelValue = imageMinValue + normalizedValue * imageRange;
    float pixelValueSq = pixelValue * pixelValue;
    
    // Atomic add to sum and sum of squares
    atomic_fetch_add_explicit(sumBuffer, pixelValue, memory_order_relaxed);
    atomic_fetch_add_explicit(sumSqBuffer, pixelValueSq, memory_order_relaxed);
}

/// Compute shader for building a histogram for median/MAD/percentile calculation
/// Uses a histogram-based approach for efficient median calculation
kernel void build_histogram(texture2d<float> inputTexture [[texture(0)]],
                            device atomic_int* histogram [[buffer(0)]],
                            constant int& numBins [[buffer(1)]],
                            constant float& imageMinValue [[buffer(2)]],
                            constant float& imageMaxValue [[buffer(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // Read pixel and convert to actual value
    float4 pixel = inputTexture.read(gid);
    float normalizedValue = pixel.r;
    float pixelValue = imageMinValue + normalizedValue * (imageMaxValue - imageMinValue);
    
    // Map to histogram bin
    float imageRange = imageMaxValue - imageMinValue;
    float normalizedForBin = (pixelValue - imageMinValue) / imageRange;
    normalizedForBin = clamp(normalizedForBin, 0.0f, 1.0f);
    
    int binIndex = min(int(normalizedForBin * float(numBins)), numBins - 1);
    
    // Atomic increment histogram bin
    atomic_fetch_add_explicit(&histogram[binIndex], 1, memory_order_relaxed);
}

/// Pass 1 of GPU-based NMAD noise estimation.
/// Computes a histogram of signed (input − background) residuals without clamping,
/// so the full noise distribution including negative sky fluctuations is preserved.
/// Residuals outside [minResidual, maxResidual] are clamped to the boundary bins.
kernel void build_residual_histogram(
    texture2d<float, access::read> inputTexture      [[texture(0)]],
    texture2d<float, access::read> backgroundTexture [[texture(1)]],
    device atomic_int*             histogram          [[buffer(0)]],
    constant int&                  numBins            [[buffer(1)]],
    constant float&                minResidual        [[buffer(2)]],
    constant float&                maxResidual        [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float residual = inputTexture.read(gid).r - backgroundTexture.read(gid).r;
    float range = maxResidual - minResidual;
    int bin = clamp(int((residual - minResidual) / range * float(numBins)), 0, numBins - 1);
    atomic_fetch_add_explicit(&histogram[bin], 1, memory_order_relaxed);
}

/// Pass 2 of GPU-based NMAD noise estimation.
/// Computes a histogram of |input − background − medianResidual| absolute deviations.
/// Values above maxAbsDev are clamped to the last bin (stars are large positive outliers
/// and don't affect the median of the sky-dominated distribution).
kernel void build_residual_mad_histogram(
    texture2d<float, access::read> inputTexture      [[texture(0)]],
    texture2d<float, access::read> backgroundTexture [[texture(1)]],
    device atomic_int*             histogram          [[buffer(0)]],
    constant int&                  numBins            [[buffer(1)]],
    constant float&                maxAbsDev          [[buffer(2)]],
    constant float&                medianResidual     [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float residual = inputTexture.read(gid).r - backgroundTexture.read(gid).r;
    float absdev = abs(residual - medianResidual);
    int bin = clamp(int(absdev / maxAbsDev * float(numBins)), 0, numBins - 1);
    atomic_fetch_add_explicit(&histogram[bin], 1, memory_order_relaxed);
}

/// Compute shader for building histogram of absolute deviations for MAD calculation
kernel void build_mad_histogram(texture2d<float> inputTexture [[texture(0)]],
                                 device atomic_int* histogram [[buffer(0)]],
                                 constant int& numBins [[buffer(1)]],
                                 constant float& imageMinValue [[buffer(2)]],
                                 constant float& imageMaxValue [[buffer(3)]],
                                 constant float& medianValue [[buffer(4)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // Read pixel and convert to actual value
    float4 pixel = inputTexture.read(gid);
    float normalizedValue = pixel.r;
    float pixelValue = imageMinValue + normalizedValue * (imageMaxValue - imageMinValue);
    
    // Calculate absolute deviation from median
    float absDeviation = abs(pixelValue - medianValue);
    
    // Map to histogram bin (use full range for deviations)
    float imageRange = imageMaxValue - imageMinValue;
    float normalizedForBin = absDeviation / imageRange;
    normalizedForBin = clamp(normalizedForBin, 0.0f, 1.0f);
    
    int binIndex = min(int(normalizedForBin * float(numBins)), numBins - 1);
    
    // Atomic increment histogram bin
    atomic_fetch_add_explicit(&histogram[binIndex], 1, memory_order_relaxed);
}

