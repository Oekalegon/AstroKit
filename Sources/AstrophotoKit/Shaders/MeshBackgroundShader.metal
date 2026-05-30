#include <metal_stdlib>
using namespace metal;

/// Pass 1 — sigma-clipped median for one grid cell.
///
/// Launch with dispatchThreadgroups(MTLSize(numCellsX, numCellsY, 1),
///                                  threadsPerThreadgroup: MTLSize(64, 1, 1))
/// Threadgroup memory (index 0): numHistBins × sizeof(int32) bytes.
///
/// Each threadgroup owns one cell.  The 64 threads collectively fill a shared
/// 256-bin histogram, then thread 0 does two-pass sigma-clipping:
///   1. IQR → σ estimate ( σ ≈ (Q75 − Q25) / 1.349 )
///   2. Recompute median within [median − 3σ, median + 3σ]
///
/// Edge cells (right/bottom of image) are handled by clamping the pixel range.
kernel void compute_mesh_cell_median(
    texture2d<float, access::read> inputTexture  [[texture(0)]],
    device float*                  cellMedians   [[buffer(0)]],
    constant int&                  cellSize      [[buffer(1)]],
    constant int&                  numCellsX     [[buffer(2)]],
    constant int&                  numHistBins   [[buffer(3)]],
    threadgroup int*               histMem       [[threadgroup(0)]],
    uint2 cellCoord  [[threadgroup_position_in_grid]],
    uint  localIdx   [[thread_index_in_threadgroup]],
    uint  localCount [[threads_per_threadgroup]]
) {
    threadgroup atomic_int* hist = (threadgroup atomic_int*)histMem;

    // Zero shared histogram
    for (uint i = localIdx; i < uint(numHistBins); i += localCount) {
        atomic_store_explicit(&hist[i], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Cell pixel bounds — edge cells may be narrower/shorter than cellSize
    int imgW = int(inputTexture.get_width());
    int imgH = int(inputTexture.get_height());
    int x0   = int(cellCoord.x) * cellSize;
    int y0   = int(cellCoord.y) * cellSize;
    int x1   = min(x0 + cellSize, imgW);
    int y1   = min(y0 + cellSize, imgH);
    int cw   = x1 - x0;
    int ch   = y1 - y0;
    int n    = cw * ch;

    // Accumulate pixels into shared histogram
    for (int p = int(localIdx); p < n; p += int(localCount)) {
        float v  = inputTexture.read(uint2(x0 + p % cw, y0 + p / cw)).r;
        int   bin = clamp(int(v * float(numHistBins)), 0, numHistBins - 1);
        atomic_fetch_add_explicit(&hist[bin], 1, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (localIdx != 0) return;

    // Pass 1: find Q25 / median / Q75 → σ ≈ (Q75 − Q25) / 1.349
    int   q1tgt  = n / 4;
    int   medtgt = n / 2;
    int   q3tgt  = (3 * n) / 4;
    int   cumul  = 0;
    float q1 = 0.0, med = 0.5, q3 = 1.0;
    bool  haveQ1 = false, haveMed = false;

    for (int i = 0; i < numHistBins; i++) {
        cumul += atomic_load_explicit(&hist[i], memory_order_relaxed);
        if (!haveQ1  && cumul >= q1tgt)  { q1  = (float(i) + 0.5f) / float(numHistBins); haveQ1  = true; }
        if (!haveMed && cumul >= medtgt)  { med = (float(i) + 0.5f) / float(numHistBins); haveMed = true; }
        if (             cumul >= q3tgt)  { q3  = (float(i) + 0.5f) / float(numHistBins); break; }
    }
    // Guard: never let sigma collapse to zero (degenerate / fully-uniform cell)
    float sigma = max((q3 - q1) / 1.349f, 1.0f / float(numHistBins));

    // Pass 2: recompute median inside the 3σ clip window
    int lo = max(0,               int((med - 3.0f * sigma) * float(numHistBins)));
    int hi = min(numHistBins - 1, int((med + 3.0f * sigma) * float(numHistBins)));

    int clippedN = 0;
    for (int i = lo; i <= hi; i++) {
        clippedN += atomic_load_explicit(&hist[i], memory_order_relaxed);
    }

    float result = med;
    if (clippedN > 0) {
        int half2 = clippedN / 2;
        cumul = 0;
        for (int i = lo; i <= hi; i++) {
            cumul += atomic_load_explicit(&hist[i], memory_order_relaxed);
            if (cumul >= half2) {
                result = (float(i) + 0.5f) / float(numHistBins);
                break;
            }
        }
    }

    cellMedians[int(cellCoord.y) * numCellsX + int(cellCoord.x)] = result;
}

/// Pass 2 — bilinear interpolation from the small cell-median grid to full resolution.
///
/// Uses access::read with manual bilinear math so no Metal sampler is required
/// (shared-storage textures may not support hardware sampling on all configurations).
/// invCellSize = 1.0 / cellSize (same for both axes; cells are square).
kernel void interpolate_mesh_background(
    texture2d<float, access::read>  cellGrid    [[texture(0)]],
    texture2d<float, access::write> bgOutput    [[texture(1)]],
    constant float&                 invCellSize [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= bgOutput.get_width() || gid.y >= bgOutput.get_height()) return;

    // Map image pixel to fractional cell-centre coordinates.
    // Cell centre i lies at image pixel (i + 0.5) * cellSize, so:
    //   cx = (px + 0.5) * invCellSize - 0.5
    float cx = (float(gid.x) + 0.5f) * invCellSize - 0.5f;
    float cy = (float(gid.y) + 0.5f) * invCellSize - 0.5f;

    int gridW = int(cellGrid.get_width());
    int gridH = int(cellGrid.get_height());

    int   x0 = max(0, min(int(floor(cx)),     gridW - 1));
    int   y0 = max(0, min(int(floor(cy)),     gridH - 1));
    int   x1 = max(0, min(int(floor(cx)) + 1, gridW - 1));
    int   y1 = max(0, min(int(floor(cy)) + 1, gridH - 1));
    float tx = cx - floor(cx);
    float ty = cy - floor(cy);

    float v00 = cellGrid.read(uint2(x0, y0)).r;
    float v10 = cellGrid.read(uint2(x1, y0)).r;
    float v01 = cellGrid.read(uint2(x0, y1)).r;
    float v11 = cellGrid.read(uint2(x1, y1)).r;

    bgOutput.write(float4(mix(mix(v00, v10, tx), mix(v01, v11, tx), ty)), gid);
}
