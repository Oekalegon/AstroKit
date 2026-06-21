/*
 * chealpix_bridge.cpp — thin C wrapper around healpix_cxx 3.83
 *
 * All pixel arithmetic is delegated to T_Healpix_Base<int64> from
 * healpix_cxx, so correctness is guaranteed by the reference implementation.
 *
 * A fresh T_Healpix_Base object is constructed per call.  The constructor
 * is O(1) (it only stores nside/order/scheme), so this carries negligible
 * overhead compared to the actual pixel computation.
 *
 * Prerequisites: run `scripts/setup_healpix.sh` to place the healpix_cxx
 * headers and sources in Sources/CHEALPix/ before building.
 */

#include "healpix_base.h"   // T_Healpix_Base, RING, NEST, SET_NSIDE
#include "pointing.h"       // pointing{theta, phi}
#include "vec3.h"           // vec3{x, y, z}

#include "include/chealpix_bridge.h"

#include <cstdlib>          // malloc, free
#include <vector>

// Use the 64-bit pixel-index variant throughout so nside up to 2^29 works.
// healpix_cxx defines int64 in datatypes.h (included transitively).
using HP = T_Healpix_Base<int64>;

extern "C" {

// ------------------------------------------------------------------ //
// RING — angular                                                       //
// ------------------------------------------------------------------ //

void ang2pix_ring(long nside, double theta, double phi, long *ipix) {
    *ipix = static_cast<long>(HP(static_cast<int64>(nside), RING, SET_NSIDE)
                              .ang2pix(pointing(theta, phi)));
}

void pix2ang_ring(long nside, long ipix, double *theta, double *phi) {
    pointing p = HP(static_cast<int64>(nside), RING, SET_NSIDE)
                 .pix2ang(static_cast<int64>(ipix));
    *theta = p.theta;
    *phi   = p.phi;
}

// ------------------------------------------------------------------ //
// RING — vector                                                        //
// ------------------------------------------------------------------ //

void vec2pix_ring(long nside, const double *vec, long *ipix) {
    *ipix = static_cast<long>(HP(static_cast<int64>(nside), RING, SET_NSIDE)
                              .vec2pix(vec3(vec[0], vec[1], vec[2])));
}

void pix2vec_ring(long nside, long ipix, double *vec) {
    vec3 v = HP(static_cast<int64>(nside), RING, SET_NSIDE)
             .pix2vec(static_cast<int64>(ipix));
    vec[0] = v.x;  vec[1] = v.y;  vec[2] = v.z;
}

// ------------------------------------------------------------------ //
// NESTED — angular                                                     //
// ------------------------------------------------------------------ //

void ang2pix_nest(long nside, double theta, double phi, long *ipix) {
    *ipix = static_cast<long>(HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                              .ang2pix(pointing(theta, phi)));
}

void pix2ang_nest(long nside, long ipix, double *theta, double *phi) {
    pointing p = HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                 .pix2ang(static_cast<int64>(ipix));
    *theta = p.theta;
    *phi   = p.phi;
}

// ------------------------------------------------------------------ //
// NESTED — vector                                                      //
// ------------------------------------------------------------------ //

void vec2pix_nest(long nside, const double *vec, long *ipix) {
    *ipix = static_cast<long>(HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                              .vec2pix(vec3(vec[0], vec[1], vec[2])));
}

void pix2vec_nest(long nside, long ipix, double *vec) {
    vec3 v = HP(static_cast<int64>(nside), NEST, SET_NSIDE)
             .pix2vec(static_cast<int64>(ipix));
    vec[0] = v.x;  vec[1] = v.y;  vec[2] = v.z;
}

// ------------------------------------------------------------------ //
// Scheme conversion                                                    //
// ------------------------------------------------------------------ //

void nest2ring(long nside, long ipnest, long *ipring) {
    *ipring = static_cast<long>(HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                                .nest2ring(static_cast<int64>(ipnest)));
}

void ring2nest(long nside, long ipring, long *ipnest) {
    *ipnest = static_cast<long>(HP(static_cast<int64>(nside), RING, SET_NSIDE)
                                .ring2nest(static_cast<int64>(ipring)));
}

// ------------------------------------------------------------------ //
// Resolution helpers                                                   //
// ------------------------------------------------------------------ //

long nside2npix(long nside) {
    return 12L * nside * nside;
}

long npix2nside(long npix) {
    if (npix <= 0) return -1L;
    long nside = static_cast<long>(sqrt(static_cast<double>(npix) / 12.0));
    return (12L * nside * nside == npix) ? nside : -1L;
}

// ------------------------------------------------------------------ //
// Cone / disc queries                                                 //
// ------------------------------------------------------------------ //

// Helper: copy a vector<int64> into a malloc'd long array.
static long fill_pixel_output(const std::vector<int64> &v, long **out) {
    long count = static_cast<long>(v.size());
    if (count == 0) { *out = nullptr; return 0; }
    *out = static_cast<long*>(malloc(static_cast<size_t>(count) * sizeof(long)));
    for (long i = 0; i < count; i++) (*out)[i] = static_cast<long>(v[i]);
    return count;
}

long query_disc_ring(long nside, double theta, double phi,
                     double radius_rad, long **pixels_out) {
    std::vector<int64> listpix;
    HP(static_cast<int64>(nside), RING, SET_NSIDE)
        .query_disc(pointing(theta, phi), radius_rad, listpix);
    return fill_pixel_output(listpix, pixels_out);
}

long query_disc_nest(long nside, double theta, double phi,
                     double radius_rad, long **pixels_out) {
    std::vector<int64> listpix;
    HP(static_cast<int64>(nside), NEST, SET_NSIDE)
        .query_disc(pointing(theta, phi), radius_rad, listpix);
    return fill_pixel_output(listpix, pixels_out);
}

long query_disc_inclusive_ring(long nside, double theta, double phi,
                                double radius_rad, long **pixels_out) {
    std::vector<int64> listpix;
    HP(static_cast<int64>(nside), RING, SET_NSIDE)
        .query_disc_inclusive(pointing(theta, phi), radius_rad, listpix);
    return fill_pixel_output(listpix, pixels_out);
}

long query_disc_inclusive_nest(long nside, double theta, double phi,
                                double radius_rad, long **pixels_out) {
    std::vector<int64> listpix;
    HP(static_cast<int64>(nside), NEST, SET_NSIDE)
        .query_disc_inclusive(pointing(theta, phi), radius_rad, listpix);
    return fill_pixel_output(listpix, pixels_out);
}

void healpix_free_pixels(long *pixels) {
    free(pixels);
}

double healpix_max_pixrad(long nside) {
    return HP(static_cast<int64>(nside), RING, SET_NSIDE).max_pixrad();
}

} // extern "C"
