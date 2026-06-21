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
 * healpix_cxx sources are vendored in Sources/CHEALPix/. No setup step
 * required — sources are part of this package.
 *
 * Exception safety: healpix_cxx uses planck_fail() which throws PlanckError
 * on invalid arguments. Every extern "C" function wraps its body in
 * try/catch(...) because a C++ exception escaping through extern "C" is
 * undefined behaviour. On error, pixel-returning functions return -1; cone
 * queries return 0 with *pixels_out = nullptr.
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
    try {
        *ipix = static_cast<long>(HP(static_cast<int64>(nside), RING, SET_NSIDE)
                                  .ang2pix(pointing(theta, phi)));
    } catch (...) { *ipix = -1; }
}

void pix2ang_ring(long nside, long ipix, double *theta, double *phi) {
    try {
        pointing p = HP(static_cast<int64>(nside), RING, SET_NSIDE)
                     .pix2ang(static_cast<int64>(ipix));
        *theta = p.theta;
        *phi   = p.phi;
    } catch (...) { *theta = -1; *phi = -1; }
}

// ------------------------------------------------------------------ //
// RING — vector                                                        //
// ------------------------------------------------------------------ //

void vec2pix_ring(long nside, const double *vec, long *ipix) {
    try {
        *ipix = static_cast<long>(HP(static_cast<int64>(nside), RING, SET_NSIDE)
                                  .vec2pix(vec3(vec[0], vec[1], vec[2])));
    } catch (...) { *ipix = -1; }
}

void pix2vec_ring(long nside, long ipix, double *vec) {
    try {
        vec3 v = HP(static_cast<int64>(nside), RING, SET_NSIDE)
                 .pix2vec(static_cast<int64>(ipix));
        vec[0] = v.x;  vec[1] = v.y;  vec[2] = v.z;
    } catch (...) { vec[0] = vec[1] = vec[2] = 0; }
}

// ------------------------------------------------------------------ //
// NESTED — angular                                                     //
// ------------------------------------------------------------------ //

void ang2pix_nest(long nside, double theta, double phi, long *ipix) {
    try {
        *ipix = static_cast<long>(HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                                  .ang2pix(pointing(theta, phi)));
    } catch (...) { *ipix = -1; }
}

void pix2ang_nest(long nside, long ipix, double *theta, double *phi) {
    try {
        pointing p = HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                     .pix2ang(static_cast<int64>(ipix));
        *theta = p.theta;
        *phi   = p.phi;
    } catch (...) { *theta = -1; *phi = -1; }
}

// ------------------------------------------------------------------ //
// NESTED — vector                                                      //
// ------------------------------------------------------------------ //

void vec2pix_nest(long nside, const double *vec, long *ipix) {
    try {
        *ipix = static_cast<long>(HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                                  .vec2pix(vec3(vec[0], vec[1], vec[2])));
    } catch (...) { *ipix = -1; }
}

void pix2vec_nest(long nside, long ipix, double *vec) {
    try {
        vec3 v = HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                 .pix2vec(static_cast<int64>(ipix));
        vec[0] = v.x;  vec[1] = v.y;  vec[2] = v.z;
    } catch (...) { vec[0] = vec[1] = vec[2] = 0; }
}

// ------------------------------------------------------------------ //
// Scheme conversion                                                    //
// ------------------------------------------------------------------ //

void nest2ring(long nside, long ipnest, long *ipring) {
    try {
        *ipring = static_cast<long>(HP(static_cast<int64>(nside), NEST, SET_NSIDE)
                                    .nest2ring(static_cast<int64>(ipnest)));
    } catch (...) { *ipring = -1; }
}

void ring2nest(long nside, long ipring, long *ipnest) {
    try {
        *ipnest = static_cast<long>(HP(static_cast<int64>(nside), RING, SET_NSIDE)
                                    .ring2nest(static_cast<int64>(ipring)));
    } catch (...) { *ipnest = -1; }
}

// ------------------------------------------------------------------ //
// Resolution helpers                                                   //
// ------------------------------------------------------------------ //

long nside2npix(long nside) {
    try {
        return 12L * nside * nside;
    } catch (...) { return -1; }
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
    try {
        std::vector<int64> listpix;
        HP(static_cast<int64>(nside), RING, SET_NSIDE)
            .query_disc(pointing(theta, phi), radius_rad, listpix);
        return fill_pixel_output(listpix, pixels_out);
    } catch (...) { *pixels_out = nullptr; return 0; }
}

long query_disc_nest(long nside, double theta, double phi,
                     double radius_rad, long **pixels_out) {
    try {
        std::vector<int64> listpix;
        HP(static_cast<int64>(nside), NEST, SET_NSIDE)
            .query_disc(pointing(theta, phi), radius_rad, listpix);
        return fill_pixel_output(listpix, pixels_out);
    } catch (...) { *pixels_out = nullptr; return 0; }
}

long query_disc_inclusive_ring(long nside, double theta, double phi,
                                double radius_rad, long **pixels_out) {
    try {
        std::vector<int64> listpix;
        HP(static_cast<int64>(nside), RING, SET_NSIDE)
            .query_disc_inclusive(pointing(theta, phi), radius_rad, listpix);
        return fill_pixel_output(listpix, pixels_out);
    } catch (...) { *pixels_out = nullptr; return 0; }
}

long query_disc_inclusive_nest(long nside, double theta, double phi,
                                double radius_rad, long **pixels_out) {
    try {
        std::vector<int64> listpix;
        HP(static_cast<int64>(nside), NEST, SET_NSIDE)
            .query_disc_inclusive(pointing(theta, phi), radius_rad, listpix);
        return fill_pixel_output(listpix, pixels_out);
    } catch (...) { *pixels_out = nullptr; return 0; }
}

void healpix_free_pixels(long *pixels) {
    free(pixels);
}

double healpix_max_pixrad(long nside) {
    try {
        return HP(static_cast<int64>(nside), RING, SET_NSIDE).max_pixrad();
    } catch (...) { return -1; }
}

} // extern "C"
