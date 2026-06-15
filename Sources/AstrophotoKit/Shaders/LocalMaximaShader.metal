#include <metal_stdlib>
using namespace metal;

struct PeakCandidate {
    int x;
    int y;
    float intensity;
};

/// Pass 1: count pixels that are strict 8-neighbour local maxima within the binary mask.
kernel void count_local_maxima(
    texture2d<float> bgFrame   [[texture(0)]],
    texture2d<float> maskFrame [[texture(1)]],
    device atomic_int* count   [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width  = bgFrame.get_width();
    uint height = bgFrame.get_height();
    if (gid.x >= width || gid.y >= height) return;

    if (maskFrame.read(gid).r < 0.5f) return;

    float center = bgFrame.read(gid).r;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(gid.x) + dx;
            int ny = int(gid.y) + dy;
            if (nx < 0 || nx >= int(width) || ny < 0 || ny >= int(height)) continue;
            if (bgFrame.read(uint2(nx, ny)).r >= center) return;
        }
    }

    atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
}

/// Pass 2: write peak positions and intensities into the pre-sized output buffer.
kernel void collect_local_maxima(
    texture2d<float> bgFrame        [[texture(0)]],
    texture2d<float> maskFrame      [[texture(1)]],
    device PeakCandidate* peaks     [[buffer(0)]],
    device atomic_int* index        [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width  = bgFrame.get_width();
    uint height = bgFrame.get_height();
    if (gid.x >= width || gid.y >= height) return;

    if (maskFrame.read(gid).r < 0.5f) return;

    float center = bgFrame.read(gid).r;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nx = int(gid.x) + dx;
            int ny = int(gid.y) + dy;
            if (nx < 0 || nx >= int(width) || ny < 0 || ny >= int(height)) continue;
            if (bgFrame.read(uint2(nx, ny)).r >= center) return;
        }
    }

    int slot = atomic_fetch_add_explicit(index, 1, memory_order_relaxed);
    peaks[slot] = PeakCandidate{int(gid.x), int(gid.y), center};
}
