#include "shim.h"
#include <math.h>
#include <time.h>

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
//   OBJECT    = target object name (if unanimous across input frames)
//   INSTRUME  = camera / instrument (if unanimous)
//   TELESCOP  = telescope name (if unanimous)
//   OBSERVAT  = observatory / site name (if unanimous)
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
    // observation metadata (NULL or empty = skip)
    const char *object_name,
    const char *camera,
    const char *telescope,
    const char *site,
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

    if (object_name && object_name[0])
        fits_update_key(fptr, TSTRING, "OBJECT",   (char *)object_name, "Target object", &status);
    if (camera && camera[0])
        fits_update_key(fptr, TSTRING, "INSTRUME", (char *)camera,      "Camera / instrument", &status);
    if (telescope && telescope[0])
        fits_update_key(fptr, TSTRING, "TELESCOP", (char *)telescope,   "Telescope", &status);
    if (site && site[0])
        fits_update_key(fptr, TSTRING, "OBSERVAT", (char *)site,        "Observatory / site name", &status);

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

    // DATE: file creation timestamp (used as deduplication key in the archive).
    {
        struct timespec _ts;
        clock_gettime(CLOCK_REALTIME, &_ts);
        struct tm *_utc = gmtime(&_ts.tv_sec);
        char _date_buf[32];
        snprintf(_date_buf, sizeof(_date_buf), "%04d-%02d-%02dT%02d:%02d:%02d",
                 _utc->tm_year + 1900, _utc->tm_mon + 1, _utc->tm_mday,
                 _utc->tm_hour, _utc->tm_min, _utc->tm_sec);
        fits_update_key(fptr, TSTRING, "DATE", _date_buf, "File creation timestamp (UTC)", &status);
    }

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

// ---------------------------------------------------------------------------
// Write a float image as a minimal FITS primary HDU.
// Used for auto-archiving result frames produced by any pipeline.
// ---------------------------------------------------------------------------
int write_result_frame_fits(
    const char *filename,
    float      *pixels,
    int         width,
    int         height,
    const char *pipeline_id,
    const char *imagetyp,
    const char *filter_name,
    int         stacked,
    int         nframes,        // 0 = skip
    double      total_exposure, // NaN = skip
    double      gain,           // NaN = skip
    double      offset_val,     // NaN = skip
    double      temperature,    // NaN = skip (mean)
    const char *object_name,    // NULL or empty = skip
    const char *camera,         // NULL or empty = skip
    const char *telescope,      // NULL or empty = skip
    const char *site,           // NULL or empty = skip (OBSERVAT)
    double      ra,             // NaN = skip (degrees)
    double      dec,            // NaN = skip (degrees)
    double      pixel_scale,    // NaN = skip (arcsec/px)
    double      focal_length,   // NaN = skip (mm)
    double      temp_min,       // NaN = skip
    double      temp_max,       // NaN = skip
    const char *date_obs,       // observation date; falls back to current UTC if empty
    const char *date_beg,       // session start; NULL or empty = skip
    const char *date_end,       // session end; NULL or empty = skip
    int         is_master,      // T → write ISMASTER = T
    int         calibrated,     // T → write CALIBRAT = T
    int        *status_out
) {
    int status = 0;
    fitsfile *fptr;

    remove(filename);

    fits_create_file(&fptr, filename, &status);
    if (status) { *status_out = status; return status; }

    long naxes[2] = { (long)width, (long)height };
    fits_create_img(fptr, FLOAT_IMG, 2, naxes, &status);

    if (object_name && object_name[0])
        fits_update_key(fptr, TSTRING, "OBJECT",   (char *)object_name, "Target object", &status);
    if (camera && camera[0])
        fits_update_key(fptr, TSTRING, "INSTRUME", (char *)camera,      "Camera / instrument", &status);
    if (telescope && telescope[0])
        fits_update_key(fptr, TSTRING, "TELESCOP", (char *)telescope,   "Telescope", &status);
    if (site && site[0])
        fits_update_key(fptr, TSTRING, "OBSERVAT", (char *)site,        "Observatory / site name", &status);
    if (pipeline_id && pipeline_id[0])
        fits_update_key(fptr, TSTRING, "PIPELINE", (char *)pipeline_id, "AstrophotoKit pipeline ID", &status);
    if (imagetyp && imagetyp[0])
        fits_update_key(fptr, TSTRING, "IMAGETYP", (char *)imagetyp, "Frame type", &status);
    if (filter_name && filter_name[0])
        fits_update_key(fptr, TSTRING, "FILTER",   (char *)filter_name, "Filter", &status);
    if (stacked) {
        int one = 1;
        fits_update_key(fptr, TLOGICAL, "STACKED", &one, "Frame is a stack", &status);
    }
    if (nframes > 0)
        fits_update_key(fptr, TINT,    "NFRAMES",  &nframes,        "Number of stacked frames", &status);
    if (!isnan(total_exposure))
        fits_update_key(fptr, TDOUBLE, "EXPTIME",  &total_exposure, "[s] Total integration time", &status);
    if (!isnan(gain))
        fits_update_key(fptr, TDOUBLE, "GAIN",     &gain,           "Camera gain (e-/ADU)", &status);
    if (!isnan(offset_val))
        fits_update_key(fptr, TDOUBLE, "OFFSET",   &offset_val,     "Camera offset (pedestal)", &status);
    if (!isnan(temperature))
        fits_update_key(fptr, TDOUBLE, "CCD-TEMP", &temperature,    "[C] CCD temperature (mean)", &status);
    if (!isnan(temp_min))
        fits_update_key(fptr, TDOUBLE, "CCD-TMIN", &temp_min,       "[C] CCD temperature (min)", &status);
    if (!isnan(temp_max))
        fits_update_key(fptr, TDOUBLE, "CCD-TMAX", &temp_max,       "[C] CCD temperature (max)", &status);
    if (!isnan(ra))
        fits_update_key(fptr, TDOUBLE, "RA",       &ra,             "[deg] Reference frame RA (J2000)", &status);
    if (!isnan(dec))
        fits_update_key(fptr, TDOUBLE, "DEC",      &dec,            "[deg] Reference frame Dec (J2000)", &status);
    if (!isnan(pixel_scale))
        fits_update_key(fptr, TDOUBLE, "PIXSCALE", &pixel_scale,    "[arcsec/px] Pixel scale", &status);
    if (!isnan(focal_length))
        fits_update_key(fptr, TDOUBLE, "FOCALLEN", &focal_length,   "[mm] Focal length", &status);

    // DATE: file creation timestamp (used as deduplication key in the archive).
    {
        struct timespec _ts;
        clock_gettime(CLOCK_REALTIME, &_ts);
        struct tm *_utc = gmtime(&_ts.tv_sec);
        char _date_buf[32];
        snprintf(_date_buf, sizeof(_date_buf), "%04d-%02d-%02dT%02d:%02d:%02d",
                 _utc->tm_year + 1900, _utc->tm_mon + 1, _utc->tm_mday,
                 _utc->tm_hour, _utc->tm_min, _utc->tm_sec);
        fits_update_key(fptr, TSTRING, "DATE", _date_buf, "File creation timestamp (UTC)", &status);
    }

    // DATE-OBS: use reference-frame observation date if provided, else current UTC.
    if (date_obs && date_obs[0]) {
        fits_update_key(fptr, TSTRING, "DATE-OBS", (char *)date_obs, "Reference frame observation date (UTC)", &status);
    } else {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        struct tm *utc = gmtime(&ts.tv_sec);
        char date_buf[32];
        snprintf(date_buf, sizeof(date_buf), "%04d-%02d-%02dT%02d:%02d:%02d",
                 utc->tm_year + 1900, utc->tm_mon + 1, utc->tm_mday,
                 utc->tm_hour, utc->tm_min, utc->tm_sec);
        fits_update_key(fptr, TSTRING, "DATE-OBS", date_buf, "Processing timestamp (UTC)", &status);
    }
    if (date_beg && date_beg[0])
        fits_update_key(fptr, TSTRING, "DATE-BEG", (char *)date_beg, "Session start (UTC)", &status);
    if (date_end && date_end[0])
        fits_update_key(fptr, TSTRING, "DATE-END", (char *)date_end, "Session end (UTC)", &status);
    if (is_master) {
        int one = 1;
        fits_update_key(fptr, TLOGICAL, "ISMASTER", &one, "Frame is a master calibration stack", &status);
    }
    if (calibrated) {
        int one = 1;
        fits_update_key(fptr, TLOGICAL, "CALIBRAT", &one, "Frame has been calibrated", &status);
    }

    long fpixel[2] = {1, 1};
    long nelements = (long)width * (long)height;
    fits_write_pix(fptr, TFLOAT, fpixel, nelements, pixels, &status);

    fits_close_file(fptr, &status);
    *status_out = status;
    return status;
}

// ---------------------------------------------------------------------------
// Append a STARCATALOG BINTABLE to an existing FITS file and write star
// quality statistics (NSTARS, MEDFWHM, MEANFWHM, MEANECC) into the primary
// HDU header.  Any pre-existing STARCATALOG extension is replaced.
// ---------------------------------------------------------------------------
int append_star_catalog_to_fits(
    const char *filename,
    int         nrows,
    int        *star_id,
    double     *centroid_x,
    double     *centroid_y,
    double     *fwhm_major,
    double     *fwhm_minor,
    double     *eccentricity,
    double     *flux,
    int        *area,
    int        *saturated,       // 0 = not saturated, 1 = saturated
    double      median_fwhm_major,
    double      median_fwhm_minor,
    double      mean_fwhm_major,
    double      mean_fwhm_minor,
    double      mean_eccentricity,
    int         n_stars,
    int        *status_out
) {
    *status_out = 0;
    int status = 0;
    fitsfile *fptr = NULL;

    fits_open_file(&fptr, filename, READWRITE, &status);
    if (status) { *status_out = status; return status; }

    // Write quality statistics into the primary HDU header
    fits_movabs_hdu(fptr, 1, NULL, &status);
    if (status) { fits_close_file(fptr, &status); *status_out = status; return status; }

    fits_update_key(fptr, TINT,    "NSTARS",   &n_stars,           "Number of detected stars",           &status);
    if (median_fwhm_major > 0.0)
        fits_update_key(fptr, TDOUBLE, "MEDFWHM",  &median_fwhm_major, "[pix] Median FWHM (major axis)",    &status);
    if (median_fwhm_minor > 0.0)
        fits_update_key(fptr, TDOUBLE, "MEDFWHM2", &median_fwhm_minor, "[pix] Median FWHM (minor axis)",    &status);
    if (mean_fwhm_major > 0.0)
        fits_update_key(fptr, TDOUBLE, "MEANFWHM", &mean_fwhm_major,   "[pix] Mean FWHM (major axis)",      &status);
    if (mean_fwhm_minor > 0.0)
        fits_update_key(fptr, TDOUBLE, "MEANFWM2", &mean_fwhm_minor,   "[pix] Mean FWHM (minor axis)",      &status);
    if (mean_eccentricity >= 0.0)
        fits_update_key(fptr, TDOUBLE, "MEANECC",  &mean_eccentricity, "Mean eccentricity (0=round)",       &status);
    if (status) { fits_close_file(fptr, &status); *status_out = status; return status; }

    // Replace any pre-existing STARCATALOG extension
    {
        int find_status = 0;
        fits_movnam_hdu(fptr, ANY_HDU, "STARCATALOG", 0, &find_status);
        if (find_status == 0) {
            int del_status = 0;
            fits_delete_hdu(fptr, NULL, &del_status);
        }
    }

    // Append new STARCATALOG BINTABLE at end of file
    char *ttype[] = { "STAR_ID",  "CENTRD_X", "CENTRD_Y", "FWHM_MAJ", "FWHM_MIN",
                      "ECCENTRC", "FLUX",     "AREA",     "SATURATD" };
    char *tform[] = { "1J",       "1D",       "1D",       "1D",       "1D",
                      "1D",       "1D",       "1J",       "1J" };
    char *tunit[] = { "",         "pix",      "pix",      "pix",      "pix",
                      "",         "",         "pix2",     "" };

    fits_create_tbl(fptr, BINARY_TBL, nrows, 9, ttype, tform, tunit, "STARCATALOG", &status);
    if (status) { fits_close_file(fptr, &status); *status_out = status; return status; }

    char pipeline_val[] = "star_detection";
    fits_update_key(fptr, TSTRING, "PIPELINE", pipeline_val, "AstrophotoKit pipeline ID", &status);

    if (nrows > 0) {
        fits_write_col(fptr, TINT,    1, 1, 1, nrows, star_id,      &status);
        fits_write_col(fptr, TDOUBLE, 2, 1, 1, nrows, centroid_x,   &status);
        fits_write_col(fptr, TDOUBLE, 3, 1, 1, nrows, centroid_y,   &status);
        fits_write_col(fptr, TDOUBLE, 4, 1, 1, nrows, fwhm_major,   &status);
        fits_write_col(fptr, TDOUBLE, 5, 1, 1, nrows, fwhm_minor,   &status);
        fits_write_col(fptr, TDOUBLE, 6, 1, 1, nrows, eccentricity, &status);
        fits_write_col(fptr, TDOUBLE, 7, 1, 1, nrows, flux,         &status);
        fits_write_col(fptr, TINT,    8, 1, 1, nrows, area,         &status);
        fits_write_col(fptr, TINT,    9, 1, 1, nrows, saturated,    &status);
    }

    fits_close_file(fptr, &status);
    *status_out = status;
    return status;
}

// ---------------------------------------------------------------------------
// Write frame quality statistics into the primary HDU header of an existing
// FITS file. Negative sentinel values (or n < 0) mean "metric not available
// — skip key". NaN sentinel for doubles also means skip.
// fits_update_key is idempotent: existing keys are overwritten in place.
//
// Quality:   NSTARS, SATSTARS, MEDFWHM, MEDECC, BACKNOIS
// Celestial: SUNALT [deg], MOONSEP [deg], MOONPHSE [0-1]
// ---------------------------------------------------------------------------
int update_quality_keys_fits(
    const char *filename,
    int         n_stars,            // < 0 → skip
    int         n_saturated,        // < 0 → skip
    double      median_fwhm,        // [pix] avg of major/minor axes; <= 0 → skip
    double      median_eccentricity,// < 0 → skip
    double      background_adu,     // [ADU]; < 0 → skip
    double      sun_altitude_deg,   // [deg] Sun alt at obs time; NaN → skip
    double      moon_separation_deg, // [deg] Moon-target separation; NaN → skip
    double      moon_illumination,  // [0-1] Moon illumination fraction; NaN → skip
    int        *status_out
) {
    *status_out = 0;
    int status = 0;
    fitsfile *fptr = NULL;

    fits_open_file(&fptr, filename, READWRITE, &status);
    if (status) { *status_out = status; return status; }

    fits_movabs_hdu(fptr, 1, NULL, &status);
    if (status) { fits_close_file(fptr, &status); *status_out = status; return status; }

    if (n_stars >= 0)
        fits_update_key(fptr, TINT,    "NSTARS",   &n_stars,             "Number of detected stars",              &status);
    if (n_saturated >= 0)
        fits_update_key(fptr, TINT,    "SATSTARS", &n_saturated,         "Number of saturated stars",             &status);
    if (median_fwhm > 0.0)
        fits_update_key(fptr, TDOUBLE, "MEDFWHM",  &median_fwhm,         "[pix] Median FWHM (avg major/minor)",   &status);
    if (median_eccentricity >= 0.0)
        fits_update_key(fptr, TDOUBLE, "MEDECC",   &median_eccentricity, "Median eccentricity (0=round)",         &status);
    if (background_adu >= 0.0)
        fits_update_key(fptr, TDOUBLE, "BACKNOIS", &background_adu,      "[ADU] Background level",                &status);
    if (!isnan(sun_altitude_deg))
        fits_update_key(fptr, TDOUBLE, "SUNALT",   &sun_altitude_deg,    "[deg] Sun altitude at obs time",        &status);
    if (!isnan(moon_separation_deg))
        fits_update_key(fptr, TDOUBLE, "MOONSEP",  &moon_separation_deg, "[deg] Moon-target angular separation",  &status);
    if (!isnan(moon_illumination))
        fits_update_key(fptr, TDOUBLE, "MOONPHSE", &moon_illumination,   "Moon illumination fraction [0-1]",      &status);

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
