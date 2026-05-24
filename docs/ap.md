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

**Multi-input pipeline:**

```bash
ap run dark_calibration \
  --input light_frame:light.fits \
  --input dark_frame:dark.fits
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

## Built-in pipelines

| ID | Description |
|----|-------------|
| `star_detection` | Detect stars and measure FWHM |
| `optical_quality` | Measure optical quality metrics |
| `collimation_reflector` | Mirror collimation analysis |
| `collimation_reflector_wavelet` | Wavelet-based collimation |
| `collimation_reflector_twophase` | Two-phase collimation |
| `collimation_reflector_radial` | Radial collimation analysis |
| `autofocus_focused` | Autofocus curve for focused images |
| `autofocus_donut` | Autofocus curve for donut (defocused) images |
| `dark_calibration` | Dark frame calibration |
| `frame_registration` | Register multiple frames against a reference |
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

## Requirements

- macOS 26+
- CFITSIO installed (`brew install cfitsio`)
- A Mac with a Metal-capable GPU
