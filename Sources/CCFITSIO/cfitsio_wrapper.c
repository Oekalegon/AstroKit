#include "shim.h"

// Wrapper functions for cfitsio to bridge Swift and C
// These functions are called from Swift using @_silgen_name

int fits_open_file_wrapper(fitsfile **fptr, const char *filename, int mode, int *status) {
    return fits_open_file(fptr, filename, mode, status);
}

int fits_close_file_wrapper(fitsfile *fptr, int *status) {
    return fits_close_file(fptr, status);
}

int fits_get_num_hdus_wrapper(fitsfile *fptr, int *numhdus, int *status) {
    return fits_get_num_hdus(fptr, numhdus, status);
}

void fits_get_errstatus_wrapper(int status, char *errText) {
    fits_get_errstatus(status, errText);
}

int fits_movabs_hdu_wrapper(fitsfile *fptr, int hduNumber, int *hduType, int *status) {
    return fits_movabs_hdu(fptr, hduNumber, hduType, status);
}

int fits_get_hdrspace_wrapper(fitsfile *fptr, int *numKeys, int *numMore, int *status) {
    return fits_get_hdrspace(fptr, numKeys, numMore, status);
}

int fits_read_keyn_wrapper(fitsfile *fptr, int index, char *keyName, char *value, char *comment, int *status) {
    return fits_read_keyn(fptr, index, keyName, value, comment, status);
}

int fits_get_img_param_wrapper(fitsfile *fptr, int maxDimensions, int *bitpix, int *naxis, LONGLONG *naxes, int *status) {
    // Convert LONGLONG array to long array for fits_get_img_param
    // fits_get_img_param expects long* but we receive LONGLONG* (64-bit) from Swift
    long naxesLong[3] = {0, 0, 0};

    // Call fits_get_img_param with long array
    int result = fits_get_img_param(fptr, maxDimensions, bitpix, naxis, naxesLong, status);

    // Copy results back to LONGLONG array for Swift
    int dimsToCopy = (*naxis < 3) ? *naxis : 3;
    for (int i = 0; i < dimsToCopy; i++) {
        naxes[i] = (LONGLONG)naxesLong[i];
    }

    return result;
}

// ---------------------------------------------------------------------------
// Internal helper: append a REGISTRATION BINTABLE to an already-open fitsfile.
// Returns the cfitsio status code (0 = success).
// ---------------------------------------------------------------------------
static int write_registration_bintable(
    fitsfile *fptr,
    int       nrows,
    int      *frame_index,
    char    **file_paths,
    char    **timestamps,
    double   *exposures,
    char    **filter_names,
    double   *gains,
    double   *offset_vals,
    char    **frame_types,
    double   *translation_x,
    double   *translation_y,
    double   *rotation_deg,
    double   *scale_val,
    int      *match_count,
    double   *rmse,
    int      *star_count,
    double   *mean_fwhm,
    double   *median_fwhm,
    double   *mean_eccentricity,
    double   *mean_position_angle,
    double   *mean_flux,
    double   *sky_background,
    double   *sky_noise,
    int       reference_frame_idx
) {
    int status = 0;

    char *ttype[] = {
        "FRAME_IDX", "FILE_PATH", "TIMESTAMP", "EXPOSURE",  "FILTER_N",
        "GAIN",      "OFFSET_V",  "FRTYPE",    "TRANS_X",   "TRANS_Y",
        "ROT_DEG",   "SCALE",     "MATCH_CNT", "RMSE",      "STAR_CNT",
        "MEAN_FWHM", "MED_FWHM",  "MEAN_ECC",  "MEAN_PA",   "MEAN_FLUX",
        "SKY_BKG",   "SKY_NOISE"
    };
    char *tform[] = {
        "1J",    "256A", "30A",  "1D",   "20A",
        "1D",    "1D",   "20A",  "1D",   "1D",
        "1D",    "1D",   "1J",   "1D",   "1J",
        "1D",    "1D",   "1D",   "1D",   "1D",
        "1D",    "1D"
    };
    char *tunit[] = {
        "",      "",     "",     "s",    "",
        "",      "",     "",     "pix",  "pix",
        "deg",   "",     "",     "pix",  "",
        "pix",   "pix",  "",     "deg",  "",
        "adu",   "adu"
    };

    fits_create_tbl(fptr, BINARY_TBL, nrows, 22, ttype, tform, tunit, "REGISTRATION", &status);
    if (status) return status;

    char pipeline_val[] = "frame_registration";
    fits_update_key(fptr, TSTRING, "PIPELINE", pipeline_val, "Pipeline ID", &status);
    fits_update_key(fptr, TINT, "REFFRAME", &reference_frame_idx, "Reference frame index", &status);

    fits_write_col(fptr, TINT,    1,  1, 1, nrows, frame_index,         &status);
    fits_write_col(fptr, TSTRING, 2,  1, 1, nrows, file_paths,          &status);
    fits_write_col(fptr, TSTRING, 3,  1, 1, nrows, timestamps,          &status);
    fits_write_col(fptr, TDOUBLE, 4,  1, 1, nrows, exposures,           &status);
    fits_write_col(fptr, TSTRING, 5,  1, 1, nrows, filter_names,        &status);
    fits_write_col(fptr, TDOUBLE, 6,  1, 1, nrows, gains,               &status);
    fits_write_col(fptr, TDOUBLE, 7,  1, 1, nrows, offset_vals,         &status);
    fits_write_col(fptr, TSTRING, 8,  1, 1, nrows, frame_types,         &status);
    fits_write_col(fptr, TDOUBLE, 9,  1, 1, nrows, translation_x,       &status);
    fits_write_col(fptr, TDOUBLE, 10, 1, 1, nrows, translation_y,       &status);
    fits_write_col(fptr, TDOUBLE, 11, 1, 1, nrows, rotation_deg,        &status);
    fits_write_col(fptr, TDOUBLE, 12, 1, 1, nrows, scale_val,           &status);
    fits_write_col(fptr, TINT,    13, 1, 1, nrows, match_count,         &status);
    fits_write_col(fptr, TDOUBLE, 14, 1, 1, nrows, rmse,                &status);
    fits_write_col(fptr, TINT,    15, 1, 1, nrows, star_count,          &status);
    fits_write_col(fptr, TDOUBLE, 16, 1, 1, nrows, mean_fwhm,           &status);
    fits_write_col(fptr, TDOUBLE, 17, 1, 1, nrows, median_fwhm,         &status);
    fits_write_col(fptr, TDOUBLE, 18, 1, 1, nrows, mean_eccentricity,   &status);
    fits_write_col(fptr, TDOUBLE, 19, 1, 1, nrows, mean_position_angle, &status);
    fits_write_col(fptr, TDOUBLE, 20, 1, 1, nrows, mean_flux,           &status);
    fits_write_col(fptr, TDOUBLE, 21, 1, 1, nrows, sky_background,      &status);
    fits_write_col(fptr, TDOUBLE, 22, 1, 1, nrows, sky_noise,           &status);

    return status;
}

// ---------------------------------------------------------------------------
// Public: write registration table only (empty primary HDU + BINTABLE).
// ---------------------------------------------------------------------------
int write_registration_fits_table(
    const char *filename,
    int nrows,
    int *frame_index,
    char **file_paths,
    char **timestamps,
    double *exposures,
    char **filter_names,
    double *gains,
    double *offset_vals,
    char **frame_types,
    double *translation_x,
    double *translation_y,
    double *rotation_deg,
    double *scale_val,
    int *match_count,
    double *rmse,
    int *star_count,
    double *mean_fwhm,
    double *median_fwhm,
    double *mean_eccentricity,
    double *mean_position_angle,
    double *mean_flux,
    double *sky_background,
    double *sky_noise,
    int reference_frame_idx,
    int *status_out
) {
    *status_out = 0;
    fitsfile *fptr = NULL;
    int status = 0;

    char filepath[4096];
    snprintf(filepath, sizeof(filepath), "!%s", filename);

    fits_create_file(&fptr, filepath, &status);
    if (status != 0) { *status_out = status; return status; }

    fits_create_img(fptr, SHORT_IMG, 0, NULL, &status);

    status = write_registration_bintable(
        fptr, nrows,
        frame_index, file_paths, timestamps, exposures,
        filter_names, gains, offset_vals, frame_types,
        translation_x, translation_y, rotation_deg, scale_val,
        match_count, rmse, star_count,
        mean_fwhm, median_fwhm, mean_eccentricity, mean_position_angle, mean_flux,
        sky_background, sky_noise,
        reference_frame_idx
    );

    fits_close_file(fptr, &status);
    *status_out = status;
    return status;
}

// ---------------------------------------------------------------------------
// Public: write stacked image (primary HDU float32) + REGISTRATION BINTABLE.
//
// Extra metadata written to the primary HDU header:
//   IMAGETYP  = "STACKED LIGHT"
//   NFRAMES   = number of frames integrated
//   EXPTIME   = total integration time (seconds)
//   FILTER    = filter name from the reference frame
//   GAIN      = camera gain from the reference frame (or -1 if unknown)
//   OFFSET    = camera offset from the reference frame (or -1 if unknown)
//   DATE-OBS  = earliest observation timestamp
//   STCKMET   = stacking method  (e.g. "average")
//   STCKNORM  = normalisation    (e.g. "none")
//   STCKREJO  = rejection method (e.g. "sigma_clip")
//   STCKRJLO  = lower rejection sigma
//   STCKRJHI  = upper rejection sigma
//   PIPELINE  = "frame_stacking"
// ---------------------------------------------------------------------------
int write_stacked_fits(
    const char *filename,
    float      *image_data,
    int         width,
    int         height,
    // registration table rows
    int         nrows,
    int        *frame_index,
    char      **file_paths,
    char      **timestamps,
    double     *exposures,
    char      **filter_names,
    double     *gains,
    double     *offset_vals,
    char      **frame_types,
    double     *translation_x,
    double     *translation_y,
    double     *rotation_deg,
    double     *scale_val,
    int        *match_count,
    double     *rmse,
    int        *star_count,
    double     *mean_fwhm,
    double     *median_fwhm,
    double     *mean_eccentricity,
    double     *mean_position_angle,
    double     *mean_flux,
    double     *sky_background,
    double     *sky_noise,
    int         reference_frame_idx,
    // stacking metadata
    double      total_exposure,
    const char *filter_name,
    double      gain,
    double      offset_val,
    const char *date_obs,
    const char *stack_method,
    const char *normalisation,
    const char *rejection,
    double      rej_low,
    double      rej_high,
    // stacked image noise
    double      stacked_sky_bkg,
    double      stacked_sky_noise,
    int        *status_out
) {
    *status_out = 0;
    fitsfile *fptr = NULL;
    int status = 0;

    char filepath[4096];
    snprintf(filepath, sizeof(filepath), "!%s", filename);

    fits_create_file(&fptr, filepath, &status);
    if (status) { *status_out = status; return status; }

    // Primary HDU: 32-bit float image
    long naxes[2] = { (long)width, (long)height };
    fits_create_img(fptr, FLOAT_IMG, 2, naxes, &status);
    if (status) { *status_out = status; fits_close_file(fptr, &status); return *status_out; }

    // --- Observation & camera keywords ---
    char imagetype[] = "STACKED LIGHT";
    fits_update_key(fptr, TSTRING, "IMAGETYP", imagetype, "Stacked master light frame", &status);

    fits_update_key(fptr, TINT,    "NFRAMES",  &nrows, "Number of frames integrated", &status);

    if (total_exposure > 0.0)
        fits_update_key(fptr, TDOUBLE, "EXPTIME", &total_exposure, "[s] Total integration time", &status);

    if (filter_name && filter_name[0] != '\0')
        fits_update_key(fptr, TSTRING, "FILTER", (char *)filter_name, "Filter used", &status);

    if (gain >= 0.0)
        fits_update_key(fptr, TDOUBLE, "GAIN", &gain, "Camera gain (reference frame)", &status);

    if (offset_val >= 0.0)
        fits_update_key(fptr, TDOUBLE, "OFFSET", &offset_val, "Camera offset (reference frame)", &status);

    if (date_obs && date_obs[0] != '\0')
        fits_update_key(fptr, TSTRING, "DATE-OBS", (char *)date_obs, "Earliest frame observation date", &status);

    // --- Stacking process keywords ---
    char pipeline_val[] = "frame_stacking";
    fits_update_key(fptr, TSTRING, "PIPELINE",  pipeline_val,        "AstrophotoKit pipeline ID",  &status);
    fits_update_key(fptr, TSTRING, "STCKMET",   (char *)stack_method, "Stacking combine method",    &status);
    fits_update_key(fptr, TSTRING, "STCKNORM",  (char *)normalisation,"Stacking normalisation",     &status);
    fits_update_key(fptr, TSTRING, "STCKREJO",  (char *)rejection,    "Pixel rejection method",     &status);
    fits_update_key(fptr, TDOUBLE, "STCKRJLO",  &rej_low,             "Rejection lower sigma",      &status);
    fits_update_key(fptr, TDOUBLE, "STCKRJHI",  &rej_high,            "Rejection upper sigma",      &status);

    // --- Noise keywords ---
    if (stacked_sky_bkg >= 0.0)
        fits_update_key(fptr, TDOUBLE, "SKY_BKG",  &stacked_sky_bkg,   "[adu] Stacked image sky background", &status);
    if (stacked_sky_noise >= 0.0)
        fits_update_key(fptr, TDOUBLE, "SKY_NOISE", &stacked_sky_noise, "[adu] Stacked image sky noise (sigma)", &status);

    // --- Image pixels ---
    long fpixel[2] = { 1, 1 };
    long nelements = (long)width * (long)height;
    fits_write_pix(fptr, TFLOAT, fpixel, nelements, image_data, &status);
    if (status) { *status_out = status; fits_close_file(fptr, &status); return *status_out; }

    // --- BINTABLE extension: registration table ---
    if (nrows > 0) {
        status = write_registration_bintable(
            fptr, nrows,
            frame_index, file_paths, timestamps, exposures,
            filter_names, gains, offset_vals, frame_types,
            translation_x, translation_y, rotation_deg, scale_val,
            match_count, rmse, star_count,
            mean_fwhm, median_fwhm, mean_eccentricity, mean_position_angle, mean_flux,
            sky_background, sky_noise,
            reference_frame_idx
        );
    }

    fits_close_file(fptr, &status);
    *status_out = status;
    return status;
}

int fits_read_img_wrapper(fitsfile *fptr, int dataType, int naxis, LONGLONG *firstPixel, LONGLONG *numElements, float *nullValue, float *array, int *anyNull, int *status) {
    // Convert LONGLONG arrays to long arrays for fits_read_pix
    // fits_read_pix expects long* (32-bit), but we receive LONGLONG* (64-bit) from Swift
    // fits_read_pix is more commonly used and may be more compatible across CFITSIO versions
    long firstPixelLong[3] = {1, 1, 1};  // Default to starting at pixel 1 in each dimension
    long numElementsLong[3] = {1, 1, 1};  // Default values

    // Copy only the dimensions that exist (naxis is typically 1, 2, or 3)
    int dimsToCopy = (naxis < 3) ? naxis : 3;
    for (int i = 0; i < dimsToCopy; i++) {
        firstPixelLong[i] = (long)firstPixel[i];
        numElementsLong[i] = (long)numElements[i];
    }

    // Calculate total number of elements to read
    long totalElements = 1;
    for (int i = 0; i < dimsToCopy; i++) {
        totalElements *= numElementsLong[i];
    }

    // Use fits_read_pix which is more straightforward and widely supported
    // Signature: fits_read_pix(fitsfile *fptr, int datatype, long *fpixel,
    //                          long nelements, void *nulval, void *array, int *anynul, int *status)
    // fpixel is the starting pixel array [1,1,1...], nelements is total number of pixels to read
    return fits_read_pix(fptr, dataType, firstPixelLong, totalElements, nullValue, array, anyNull, status);
}
