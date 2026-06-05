#include <metal_stdlib>
using namespace metal;

/// Extracts a single column from a texture into a 1D float buffer.
/// Each thread handles one row. The .r channel carries the normalized intensity value
/// for both grayscale (r32Float) and RGBA textures loaded by FITSImageView.
kernel void cross_section_column(
    texture2d<float, access::read> tex [[texture(0)]],
    device float                  *out [[buffer(0)]],
    constant uint                 &col [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= tex.get_height()) return;
    out[gid] = tex.read(uint2(col, gid)).r;
}

/// Extracts a single row from a texture into a 1D float buffer.
/// Each thread handles one column.
kernel void cross_section_row(
    texture2d<float, access::read> tex [[texture(0)]],
    device float                  *out [[buffer(0)]],
    constant uint                 &row [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= tex.get_width()) return;
    out[gid] = tex.read(uint2(gid, row)).r;
}
