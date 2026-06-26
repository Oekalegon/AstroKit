# ap — AstrophotoKit CLI

`ap` is the command-line interface for AstrophotoKit. It lets you run any registered pipeline directly on FITS files from a terminal.

## Installation

Build and install with Swift Package Manager:

```bash
swift build -c release --product ap
cp .build/release/ap /usr/local/bin/ap
```

## Commands

### `ap list`

Lists all registered pipelines.

```
ap list
```

```
Pipelines (9):
  autofocus-donut
    Autofocus for out-of-focus (donut) images
  autofocus-focused
    Autofocus for focused images
  collimation-reflector
    Mirror collimation analysis
  ...
```

Add `--processors` to list individual processors instead:

```
ap list --processors
```

---

### `ap inspect <pipeline-id>`

Shows a pipeline's required inputs, tunable parameters, and step list.

```
ap inspect star_detection
```

```
Pipeline: star_detection
Name:     Star Detection Pipeline
About:    Detects stars in astronomical images …

Inputs (1):
  input_frame

Parameters (--param key=value):
  blur_radius [default: 3.0]  — Blur radius in pixels
  threshold_value [default: 3.0]  — Threshold value (sigma multiplier)
  …

Steps (10):
  Grayscale [grayscale] — processor: grayscale
  Gaussian Blur [blur] — processor: gaussian_blur
  …
```

---

### `ap run <pipeline-id> --input <file>`

Executes a pipeline on a FITS file and prints the results.

**Single-input pipeline (most pipelines):**

```bash
ap run star_detection --input M51.fits
```

**Multi-frame pipeline (FrameSet input):**

```bash
ap run master_dark --input @frameset:9895364D-AD01-4BC9-A10A-CD9911648104
```

**With parameters:**

```bash
ap run star_detection --input M51.fits \
  --param threshold_value=4.0 \
  --param blur_radius=2.0
```

**JSON output (for scripting):**

```bash
ap run star_detection --input M51.fits --json
```

```json
{
  "elapsed_seconds": 1.23,
  "frame_count": 2,
  "pipeline": "star_detection",
  "tables": [
    {
      "columns": ["label", "centroid_x", "centroid_y", "fwhm_major", "fwhm_minor"],
      "rows": [
        { "label": 1, "centroid_x": 512.3, "centroid_y": 401.1, "fwhm_major": 3.2, "fwhm_minor": 3.0 },
        ...
      ]
    }
  ]
}
```

---

### `ap headers <file>`

Prints the full FITS header of a file, grouped by topic (Object, Observation, Telescope & Optics, Camera, Site & Conditions, Astrometric Solution, Processing & Stacking, Quality, File Structure) with human readable names. The original FITS keyword is shown in brackets after each value.

```bash
ap headers M51.fits
```

```
Object
──────────
  Object           M 101        [OBJECT]
  Right Ascension  14 03 09.58  [OBJCTRA]
  Declination      54 18 58.86  [OBJCTDEC]
  ...

Camera
──────────
  Camera              PlayerOne CCD Ares-M Pro  [INSTRUME]
  Gain                125  [GAIN]
  Sensor Temperature  -10.1 °C  [CCD-TEMP]
  ...
```

Add `--json` for machine-readable output. Each entry carries the original FITS keyword, the human readable name, the raw value, and the formatted display value; the response also includes the complete original header as a flat `header` object:

```bash
ap headers M51.fits --json
```

```json
{
  "file": "/path/to/M51.fits",
  "groups": [
    {
      "group": "Object",
      "entries": [
        { "keyword": "OBJECT", "name": "Object", "value": "M 101   ", "display": "M 101" },
        { "keyword": "RA", "name": "Right Ascension", "value": 210.8141, "unit": "°", "display": "210.8141 °" }
      ]
    }
  ],
  "header": { "OBJECT": "M 101   ", "RA": 210.8141, "...": "..." }
}
```

The same data is available for archived frames via `ap-archive headers <frame-id>`, and to MCP clients through the `fits_headers` tool of `astrokit-mcp` (by `path` or archive `frame_id`).

## Built-in pipelines

| ID | Description |
|----|-------------|
| `frame_quality` | Measure per-frame quality: star count, FWHM, eccentricity, SNR, and background statistics |
| `calibration_quality` | Measure calibration-frame quality: noise sigma, mean level, hot pixels |
| `star_detection` | Detect stars, measure FWHM/eccentricity, and update the source FITS file |
| `optical_quality` | Measure optical quality metrics |
| `collimation_reflector` | Mirror collimation analysis |
| `collimation_reflector_wavelet` | Wavelet-based collimation |
| `collimation_reflector_twophase` | Two-phase collimation |
| `collimation_reflector_radial` | Radial collimation analysis |
| `autofocus_focused` | Autofocus curve for focused images |
| `autofocus_donut` | Autofocus curve for donut (defocused) images |
| `master_bias` | Stack bias frames into a master bias |
| `master_dark` | Stack dark frames into a master dark |
| `master_darkflat` | Stack dark flat frames into a master dark flat |
| `calibrate_flats` | Subtract master dark flat or master bias from each flat frame |
| `master_flat` | Stack calibrated flat frames into a master flat |
| `calibrate_lights` | Apply master dark and master flat to light frames |
| `frame_registration` | Register multiple frames — 4-star quad patterns |
| `frame_registration_triangle` | Register multiple frames — 3-star triangle patterns (sparse fields) |
| `frame_stacking` | Register and stack multiple frames into a master light |

---

## Multi-frame pipelines

### `frame_registration`

Aligns a set of frames to a common reference and outputs a registration table with per-frame transforms and quality metrics.

```bash
# Pass individual files:
ap run frame_registration \
  --input input_frames:frame1.fits \
  --input input_frames:frame2.fits \
  --input input_frames:frame3.fits \
  --output registration.fits

# Or pass a directory of FITS files:
ap run frame_registration \
  --input input_frames:/path/to/lights/ \
  --output registration.fits

# Save as CSV instead:
ap run frame_registration \
  --input input_frames:/path/to/lights/ \
  --output registration.csv --format csv
```

The output FITS contains a `REGISTRATION` BINTABLE extension with columns for each frame's translation, rotation, scale, star count, FWHM, and match quality.

---

### `frame_registration_triangle`

Aligns a set of frames using **3-star triangle pattern matching** instead of 4-star quads. Triangle patterns produce C(n,3) combinations vs C(n,4) for quads, so the pattern space is roughly `n/4` times larger for the same star count. This makes triangle registration the better choice when the star field is sparse and `frame_registration` cannot find enough quad matches.

The output schema is identical to `frame_registration` — the same `registration_table` columns and optional `reference_stars` table — so both pipelines are drop-in interchangeable.

```bash
# Sparse-field registration with triangle patterns:
ap run frame_registration_triangle \
  --input input_frames:/path/to/lights/ \
  --output registration.fits

# Increase k-neighbours for even more pattern coverage:
ap run frame_registration_triangle \
  --input input_frames:/path/to/lights/ \
  --param k_neighbors=12 \
  --output registration.fits
```

**Parameters unique to triangle registration:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `k_neighbors` | `8` | Nearest neighbours per star used to form triangles (each star contributes C(k,2) triangles) |

All other parameters (`match_threshold`, `min_matches`, `ransac_iterations`, `inlier_threshold`, `blur_radius`, `threshold_value`, `erosion_kernel_size`, `dilation_kernel_size`, `max_stars`, `min_distance_percent`, `max_scale_deviation`, `ratio_threshold`, `min_success_rate`, `max_fwhm_ratio`, `reference_frame`) are identical to `frame_registration`.

**When to use each algorithm:**

| Situation | Recommended pipeline |
|-----------|----------------------|
| Dense star field (≥ 10 bright stars per frame) | `frame_registration` |
| Sparse field or galaxy/nebula centres (5–10 stars) | `frame_registration_triangle` |
| Very sparse (< 5 stars) or translation-only | Phase-correlation or plate-solving |

---

### `frame_stacking`

Registers and stacks a set of frames into a master stacked light. The output FITS contains the stacked image in the primary HDU (32-bit float) with full FITS header metadata, plus a `REGISTRATION` BINTABLE extension with the per-frame registration data.

```bash
# Basic stacking with defaults (average, no normalisation, sigma-clip rejection):
ap run frame_stacking \
  --input input_frames:/path/to/lights/ \
  --output stacked.fits

# Median stack with multiplicative normalisation:
ap run frame_stacking \
  --input input_frames:/path/to/lights/ \
  --param method=median \
  --param normalisation=multiplicative \
  --output stacked.fits

# Custom rejection thresholds:
ap run frame_stacking \
  --input input_frames:/path/to/lights/ \
  --param pixel_rejection=winsorized \
  --param rejection_low=2.5 \
  --param rejection_high=2.5 \
  --output stacked.fits
```

**Parameters:**

| Parameter | Default | Options |
|-----------|---------|---------|
| `method` | `average` | `average`, `sum`, `median`, `max_pixel`, `min_pixel` |
| `normalisation` | `none` | `none`, `additive`, `multiplicative`, `additive_scaling`, `multiplicative_scaling` |
| `pixel_rejection` | `sigma_clip` | `none`, `sigma_clip`, `winsorized` |
| `rejection_low` | `3.0` | Lower rejection sigma (applies to `sigma_clip` and `winsorized`) |
| `rejection_high` | `3.0` | Upper rejection sigma (applies to `sigma_clip` and `winsorized`) |

**FITS header keywords written to the stacked output:**

| Keyword | Description |
|---------|-------------|
| `IMAGETYP` | `"STACKED LIGHT"` |
| `NFRAMES` | Number of frames integrated |
| `EXPTIME` | Total integration time (sum of per-frame exposures, seconds) |
| `FILTER` | Filter from the reference frame |
| `GAIN` | Camera gain from the reference frame |
| `OFFSET` | Camera offset from the reference frame |
| `DATE-OBS` | Earliest observation timestamp |
| `PIPELINE` | `"frame_stacking"` |
| `STCKMET` | Combine method used |
| `STCKNORM` | Normalisation method used |
| `STCKREJO` | Pixel rejection method used |
| `STCKRJLO` | Lower rejection sigma |
| `STCKRJHI` | Upper rejection sigma |

---

## Star detection and FITS catalog output

When `star_detection` runs on a file loaded from disk, it modifies the **source FITS file in-place**:

1. **Primary HDU header** — quality statistics are written as FITS keywords:

   | Keyword | Description |
   |---------|-------------|
   | `NSTARS` | Number of detected stars |
   | `MEDFWHM` | Median FWHM — major axis (pixels) |
   | `MEDFWHM2` | Median FWHM — minor axis (pixels) |
   | `MEANFWHM` | σ-clipped mean FWHM — major axis (pixels) |
   | `MEANFWM2` | σ-clipped mean FWHM — minor axis (pixels) |
   | `MEANECC` | Mean eccentricity across non-saturated stars (0 = round) |

2. **`STARCATALOG` BINTABLE extension** — one row per detected star:

   | Column | Unit | Description |
   |--------|------|-------------|
   | `STAR_ID` | — | Sequential star index |
   | `CENTRD_X` | pix | Centroid X position |
   | `CENTRD_Y` | pix | Centroid Y position |
   | `FWHM_MAJ` | pix | FWHM along the major axis |
   | `FWHM_MIN` | pix | FWHM along the minor axis |
   | `ECCENTRC` | — | Eccentricity (0 = circular, 1 = fully elongated) |
   | `FLUX` | — | Integrated intensity from image moments |
   | `AREA` | pix² | Number of pixels in the connected component |
   | `SATURATD` | — | 1 if the star is saturated (≥ 90 % full-scale), 0 otherwise |

The operation is idempotent — re-running `star_detection` on the same file replaces any existing `STARCATALOG` extension and overwrites the quality keywords.

```bash
ap run star_detection --input M51.fits
# M51.fits now contains NSTARS / MEDFWHM / MEANECC in its header
# and a STARCATALOG BINTABLE extension with one row per star
```

> **Note:** This in-place update only occurs when the input file has an accessible path on disk. Frames created programmatically (e.g. in-memory pipeline chains) are skipped without error.

---

## Frame quality pipeline

The `frame_quality` pipeline runs on a single archived light frame and writes quality metrics back to the archive. Results are also archived automatically when `ASTROARCHIVE_PATH` is set.

In addition, the quality summary is written into the **source FITS file's primary header** (in-place, idempotent):

| Keyword | Description |
|---------|-------------|
| `NSTARS` | Number of detected stars |
| `SATSTARS` | Number of saturated stars |
| `MEDFWHM` | Median FWHM in pixels (average of major and minor axes) |
| `MEDECC` | Median eccentricity (0 = round) |
| `BACKNOIS` | Background level in ADU |

These are the same keywords the archive reads back on import, so quality metrics survive a file being re-imported into a fresh archive.

```bash
# Run on a single file:
ap run frame_quality --input image.fits

# Run on every frame in an archive frameset (reads UUID from archive):
ap run frame_quality --input @frameset:3F7A1234-…

# Or use the dedicated frameset command (skips frames that already have metrics):
ap-archive frameset quality 3F7A1234-…
ap-archive frameset quality 3F7A1234-… --force          # re-run all
```

### Output columns

The pipeline produces a single-row `frame_quality` table:

| Column | Type | Description |
|--------|------|-------------|
| `star_count` | integer | Genuine point sources: saturated stars + unsaturated sources that passed the FWHM and eccentricity filters. |
| `saturated_star_count` | integer | Stars whose peak pixel ≥ 90 % of full-scale. |
| `excluded_source_count` | integer | Blobs rejected as non-stellar by `max_fwhm_arcsec` or `max_eccentricity` (galaxy cores, nebulae, cosmic rays, satellite trails). |
| `median_fwhm` | number | Median FWHM in pixels (average of major + minor axes). Sources above `max_fwhm_arcsec` or `max_eccentricity` are excluded. |
| `median_eccentricity` | number | Median eccentricity 0–1 (0 = circular). Same exclusion filters as `median_fwhm`. |
| `median_snr` | number | Median peak SNR of non-outlier, non-saturated sources (peak signal / background noise). Only present when pixel scale or FITS scale info is available for noise conversion. |
| `low_snr_count` | integer | Number of sources with peak SNR below `low_snr_threshold` (default 5). |
| `background_level` | number | Normalised sky background level 0–1 (backward compatibility). |
| `threshold_sigma_used` | number | The `threshold_value` sigma multiplier that was active during detection. |
| `background_level_adu` | number | Sky background in ADU (requires FITS scale info). |
| `background_noise_sigma_adu` | number | Per-pixel sky noise sigma in ADU (NMAD of the background-subtracted frame). The key metric for judging detection sensitivity. |
| `effective_detection_threshold_adu` | number | ADU value a source must exceed to be detected: `background_adu + threshold_sigma × noise_sigma_adu`. |
| `background_level_electrons` | number | Sky background in electrons (requires EGAIN in FITS header). Cross-camera comparable. |
| `suggested_threshold_value` | number | Recommended `threshold_value` for re-running: `clamp(median_snr / 3, 1.5, 5.0)`. Present only when `median_snr` is available. |
| `suggested_blur_radius` | number | Recommended `blur_radius` for re-running: `clamp(median_fwhm / 4, 1.0, 5.0)`. Present only when `median_fwhm` is available. |
| `suggested_max_fwhm_arcsec` | number | Recommended `max_fwhm_arcsec` cutoff: `max(4.0, 3 × median_fwhm_arcsec)`. Present only when `median_fwhm` and `PIXSCALE` are available. |

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `threshold_value` | 3.0 | Sigma multiplier for the binary threshold step. Also determines `effective_detection_threshold_adu`. |
| `max_fwhm_arcsec` | 8.0 | Exclude sources with FWHM above this value (arcseconds) from the seeing statistics. Requires `PIXSCALE` in the FITS header. Galaxy cores and extended nebulae are automatically filtered. |
| `max_eccentricity` | 0.9 | Exclude sources with eccentricity above this value from the statistics. Filters cosmic rays and satellite trails. |
| `low_snr_threshold` | 5.0 | Peak SNR below which a source is counted in `low_snr_count`. |

### Interpreting the output

The `background_noise_sigma_adu` and `effective_detection_threshold_adu` columns are particularly useful for narrowband data:

- A high `background_noise_sigma_adu` relative to `background_level_adu` indicates a noisy sky or insufficient integration time.
- Comparing `effective_detection_threshold_adu` across frames with different `threshold_value` settings lets you tune detection sensitivity without re-running the pipeline.
- `median_snr` < 5 on most sources suggests the frame is under-exposed or the seeing was poor. For narrowband, values of 5–15 are typical for reasonable sub-frames.
- `low_snr_count` close to `star_count` means most detections are marginal; consider raising `threshold_value` to reduce false positives.

### Parameter suggestions

The `suggested_*` columns give ready-to-use values for a follow-up run:

```bash
# Read suggestions from the first run, then re-run with them:
ap run frame_quality --input M51.fits \
  --param threshold_value=2.1 \
  --param blur_radius=1.8
```

- **`suggested_threshold_value`** lowers the threshold when sources are bright (high `median_snr`), and raises it when they are marginal. Formula: `clamp(median_snr / 3, 1.5, 5.0)`.
- **`suggested_blur_radius`** matches the blur kernel to the measured PSF size so noise smoothing doesn't smear stars. Formula: `clamp(median_fwhm / 4, 1.0, 5.0)`.
- **`suggested_max_fwhm_arcsec`** sets the extended-source cutoff to three times the measured seeing, with a 4″ floor. Requires `PIXSCALE` in the FITS header.

---

## Auto-archiving

When `ASTROARCHIVE_PATH` is set (or `--archive-path` is passed), any pipeline run that produces Frame outputs automatically archives those results:

```bash
export ASTROARCHIVE_PATH=~/AstroArchive

ap run frame_stacking \
  --input input_frames:/path/to/lights/ \
  --output stacked.fits
# → Archived result → D1E2F3A4-5678-9ABC-DEF0-123456789ABC
```

A provenance record is written alongside the frame, capturing the pipeline ID, all parameters, and every input file path (with archive UUIDs for inputs that are already in the archive). Use `ap-archive info <uuid>` to view this data later.

Auto-archiving is silent on success and prints a warning on failure — it never fails the pipeline run itself.

## Requirements

- macOS 26+
- CFITSIO installed (`brew install cfitsio`)
- A Mac with a Metal-capable GPU