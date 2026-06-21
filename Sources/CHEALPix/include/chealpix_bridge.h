/*
 * chealpix_bridge.h — C interface over healpix_cxx 3.83
 *
 * This header exposes the same function signatures as the traditional
 * chealpix.h so the Swift layer can import it as a plain C module.
 * All angles are in radians; theta is colatitude (0 = north pole, π = south
 * pole); phi is longitude [0, 2π).  nside must be a positive power of 2.
 */

#ifndef CHEALPIX_BRIDGE_H
#define CHEALPIX_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/*  Angular ↔ pixel (RING ordering)                                   */
/* ------------------------------------------------------------------ */

void ang2pix_ring(long nside, double theta, double phi, long *ipix);
void pix2ang_ring(long nside, long ipix, double *theta, double *phi);

/* ------------------------------------------------------------------ */
/*  Angular ↔ pixel (NESTED ordering)                                 */
/* ------------------------------------------------------------------ */

void ang2pix_nest(long nside, double theta, double phi, long *ipix);
void pix2ang_nest(long nside, long ipix, double *theta, double *phi);

/* ------------------------------------------------------------------ */
/*  Unit vector ↔ pixel (RING ordering)                               */
/* ------------------------------------------------------------------ */

/** vec must point to storage for at least 3 doubles: [x, y, z]. */
void vec2pix_ring(long nside, const double *vec, long *ipix);
void pix2vec_ring(long nside, long ipix, double *vec);

/* ------------------------------------------------------------------ */
/*  Unit vector ↔ pixel (NESTED ordering)                             */
/* ------------------------------------------------------------------ */

void vec2pix_nest(long nside, const double *vec, long *ipix);
void pix2vec_nest(long nside, long ipix, double *vec);

/* ------------------------------------------------------------------ */
/*  Scheme conversion                                                  */
/* ------------------------------------------------------------------ */

void nest2ring(long nside, long ipnest, long *ipring);
void ring2nest(long nside, long ipring, long *ipnest);

/* ------------------------------------------------------------------ */
/*  Resolution helpers                                                 */
/* ------------------------------------------------------------------ */

long nside2npix(long nside);
long npix2nside(long npix);

/* ------------------------------------------------------------------ */
/*  Cone / disc queries                                                */
/* ------------------------------------------------------------------ */

/**
 * Return the pixel indices whose *centres* lie within `radius_rad` of the
 * direction (theta, phi).  The result array is heap-allocated; the caller
 * must free it with healpix_free_pixels().
 *
 * @param pixels_out  set to a malloc'd array of `long` pixel indices
 * @return            number of pixels in the array
 */
long query_disc_ring(long nside, double theta, double phi,
                     double radius_rad, long **pixels_out);
long query_disc_nest(long nside, double theta, double phi,
                     double radius_rad, long **pixels_out);

/**
 * Like query_disc_*, but also includes pixels that *overlap* the disc
 * boundary (conservative — may return a few extra pixels).
 */
long query_disc_inclusive_ring(long nside, double theta, double phi,
                                double radius_rad, long **pixels_out);
long query_disc_inclusive_nest(long nside, double theta, double phi,
                                double radius_rad, long **pixels_out);

/** Free a pixel array returned by any query_disc_* function. */
void healpix_free_pixels(long *pixels);

/** Maximum angular distance (radians) between a pixel centre and any of its
 *  corners.  Add this to a search radius to get inclusive coverage. */
double healpix_max_pixrad(long nside);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CHEALPIX_BRIDGE_H */
