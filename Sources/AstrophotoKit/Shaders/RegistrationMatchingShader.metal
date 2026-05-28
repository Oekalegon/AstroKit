#include <metal_stdlib>
using namespace metal;

/// Forward pass: for each target descriptor, find the best and second-best matching
/// reference descriptor by L2 distance.
///
/// One thread per target descriptor (ti).
/// Outputs:
///   fwd_best_idx  — index of best reference match (-1 if none)
///   fwd_best_dist — distance to best match
///   fwd_sec_dist  — distance to second-best match (INFINITY if only one candidate)
///
/// counts.x = n_ref, counts.y = n_tgt
kernel void triangle_match_forward(
    device const float2 *ref_desc    [[buffer(0)]],
    device const float2 *tgt_desc    [[buffer(1)]],
    device       int32_t *fwd_best_idx  [[buffer(2)]],
    device       float   *fwd_best_dist [[buffer(3)]],
    device       float   *fwd_sec_dist  [[buffer(4)]],
    constant     uint2   &counts        [[buffer(5)]],
    uint ti [[thread_position_in_grid]]
) {
    if (ti >= counts.y) return;
    float2 tq   = tgt_desc[ti];
    float  best = INFINITY, sec = INFINITY;
    int32_t bi  = -1;
    for (uint ri = 0; ri < counts.x; ri++) {
        float2 d    = tq - ref_desc[ri];
        float  dist = sqrt(dot(d, d));
        if (dist < best) { sec = best; best = dist; bi = int32_t(ri); }
        else if (dist < sec) { sec = dist; }
    }
    fwd_best_idx[ti]  = bi;
    fwd_best_dist[ti] = best;
    fwd_sec_dist[ti]  = sec;
}

// MARK: - 4D quad descriptor matching (dx3, dy3, dx4, dy4)

/// Forward pass for 4-star quad descriptors. Identical to triangle_match_forward but
/// operates on float4 (dx3, dy3, dx4, dy4).
kernel void quad_match_forward(
    device const float4 *ref_desc    [[buffer(0)]],
    device const float4 *tgt_desc    [[buffer(1)]],
    device       int32_t *fwd_best_idx  [[buffer(2)]],
    device       float   *fwd_best_dist [[buffer(3)]],
    device       float   *fwd_sec_dist  [[buffer(4)]],
    constant     uint2   &counts        [[buffer(5)]],
    uint ti [[thread_position_in_grid]]
) {
    if (ti >= counts.y) return;
    float4 tq   = tgt_desc[ti];
    float  best = INFINITY, sec = INFINITY;
    int32_t bi  = -1;
    for (uint ri = 0; ri < counts.x; ri++) {
        float4 d    = tq - ref_desc[ri];
        float  dist = sqrt(dot(d, d));
        if (dist < best) { sec = best; best = dist; bi = int32_t(ri); }
        else if (dist < sec) { sec = dist; }
    }
    fwd_best_idx[ti]  = bi;
    fwd_best_dist[ti] = best;
    fwd_sec_dist[ti]  = sec;
}

/// Backward pass for 4-star quad descriptors.
kernel void quad_match_backward(
    device const float4 *ref_desc    [[buffer(0)]],
    device const float4 *tgt_desc    [[buffer(1)]],
    device       int32_t *bwd_best_idx [[buffer(2)]],
    constant     uint2   &counts       [[buffer(3)]],
    uint ri [[thread_position_in_grid]]
) {
    if (ri >= counts.x) return;
    float4 rq   = ref_desc[ri];
    float  best = INFINITY;
    int32_t bi  = -1;
    for (uint ti = 0; ti < counts.y; ti++) {
        float4 d    = rq - tgt_desc[ti];
        float  dist = sqrt(dot(d, d));
        if (dist < best) { best = dist; bi = int32_t(ti); }
    }
    bwd_best_idx[ri] = bi;
}

// MARK: - 2D triangle descriptor matching (ratio1, ratio2)

/// Backward pass: for each reference descriptor, find the best matching target descriptor.
/// Used together with the forward pass for mutual cross-check filtering.
///
/// One thread per reference descriptor (ri).
/// counts.x = n_ref, counts.y = n_tgt
kernel void triangle_match_backward(
    device const float2 *ref_desc    [[buffer(0)]],
    device const float2 *tgt_desc    [[buffer(1)]],
    device       int32_t *bwd_best_idx [[buffer(2)]],
    constant     uint2   &counts       [[buffer(3)]],
    uint ri [[thread_position_in_grid]]
) {
    if (ri >= counts.x) return;
    float2 rq   = ref_desc[ri];
    float  best = INFINITY;
    int32_t bi  = -1;
    for (uint ti = 0; ti < counts.y; ti++) {
        float2 d    = rq - tgt_desc[ti];
        float  dist = sqrt(dot(d, d));
        if (dist < best) { best = dist; bi = int32_t(ti); }
    }
    bwd_best_idx[ri] = bi;
}
