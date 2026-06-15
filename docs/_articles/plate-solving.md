---
layout: article
title: Plate Solving — Native Implementation Plan
series: "Design"
series_order: 2
date: 2026-05-28
categories: astrophotography pipelines image-processing design
published: false
---

# Plate Solving — Native Implementation Plan

## Overview

Plate solving (astrometric calibration) determines the sky coordinates of every pixel in an astrophotography frame by matching detected stars to a reference catalog. A solved frame carries a World Coordinate System (WCS) embedded in its FITS header, allowing any pixel to be mapped to RA/Dec and back.

This document describes the plan for implementing native plate solving in AstrophotoKit using the astrometry.net index file format.

---

## Why Native?

AstrophotoKit already contains the key building blocks:

- **Full star detection pipeline** — grayscale, blur, background subtraction, threshold, morphological ops, connected components, FWHM measurement, FWHM-based extended-source filter (`RegistrationCore.detectStars`)
- **Quad generation** — `QuadsProcessor` produces descriptors in `(x3, y3, x4, y4)` format using the same normalization as astrometry.net (longest pair as baseline, lexicographically canonical variant)
- **2D KD-tree** — `KDTree.swift`, clean and extensible
- **RANSAC + least-squares similarity** — `RegistrationCore.ransac` and `RegistrationCore.leastSquaresSimilarity`
- **cfitsio integration** — `CCFITSIO` module already wired, FITS binary table I/O available

The quad descriptor format is directly compatible with the astrometry.net index file format. This is the expensive piece, and it is already done correctly.

---

## Index Files

Astrometry.net distributes pre-built FITS index files derived from the Tycho-2 and 2MASS catalogs. They cover the full sky and come in a series of scales (index-4100 through index-5200) tuned to different field-of-view sizes. The full set is ~30 GB, but only the series matching the imaging setup's FOV are needed — typically a few hundred MB.

Each index file is a FITS file containing:

| Extension | Content |
|---|---|
| Primary HDU | Scale metadata (`SCALE_U`, `SCALE_L`, `HEALPIX`, `HPNSIDE`, `NSTARS`, `NQUADS`) |
| `quads` binary table | One row per catalog quad: 4 × uint32 star indices (`ids` column) |
| `stars` binary table | One row per catalog star: `ra`, `dec` in degrees (+ optional magnitude columns) |
| KD-tree tables | Custom flattened balanced KD-tree over 4D descriptor space |

The approach taken here reads the `stars` and `quads` tables directly via cfitsio and rebuilds a Swift KD-tree over the computed descriptors at load time, avoiding the need to parse the custom KD-tree binary format.

---

## Architecture

```
PlatesolveProcessor
├── IndexLoader              — loads + caches astrometry.net index files
│   ├── reads stars table (cfitsio / CCFITSIO)
│   ├── reads quads table (cfitsio / CCFITSIO)
│   └── builds DescriptorIndex (4D KD-tree)
│
├── star detection           — reuses RegistrationCore.detectStars
├── QuadsProcessor           — reuses existing, already compatible
│
├── QuadMatcher              — matches image quad descriptors to catalog
│   ├── 4D range search in DescriptorIndex
│   └── returns candidate pixel ↔ RA/Dec star correspondences
│
├── WCSSolver                — derives WCS from matched correspondences
│   ├── gnomonic projection (TAN) in Swift
│   ├── least-squares CD matrix fit (reuses solve4x4)
│   └── optional SIP distortion pass
│
└── WCSWriter                — writes WCS keywords to FITS header
    └── via wcslib (CWCSLib) or direct FITS keyword writing
```

---

## Component Details

### 1. Index Loader

**File:** `Sources/AstrophotoKit/Platesolver/IndexLoader.swift`

Responsible for loading an astrometry.net index FITS file and producing an in-memory `DescriptorIndex`.

**Steps:**
1. Open the FITS file using cfitsio (`fits_open_file`).
2. Navigate to the `stars` binary table extension; read `ra` and `dec` columns into `[Double]` arrays.
3. Navigate to the `quads` binary table extension; read the `ids` column (4 × uint32 per row) into `[(Int, Int, Int, Int)]`.
4. For each quad, project the 4 catalog stars to a local tangent plane centred on the quad's barycentre using a TAN projection.
5. Compute the quad descriptor `(x3, y3, x4, y4)` using the same normalization as `QuadsProcessor` (longest pair as baseline, canonical variant).
6. Build a 4D KD-tree over all computed descriptors.
7. Cache the loaded index keyed by file path; skip reload if already loaded.

**Key types:**
```swift
struct CatalogStar { let ra: Double; let dec: Double }
struct CatalogQuad { let stars: (Int, Int, Int, Int); let descriptor: QuadDescriptor }
struct QuadDescriptor { let x3, y3, x4, y4: Double }
struct DescriptorIndex { let stars: [CatalogStar]; let quads: [CatalogQuad]; let kdtree: KDTree4D }
```

**Error conditions:** file not found, wrong FITS structure, incompatible scale.

---

### 2. 4D KD-Tree

**File:** `Sources/AstrophotoKit/Utilities/KDTree.swift` (extend existing)

The existing `KDTree` is 2D and tied to `Point2D`. The extension generalises it to N dimensions.

**Approach:** Introduce a `PointND` protocol (or a concrete `Point4D` struct) and make `KDTree` generic or add a parallel `KDTreeND` class. The algorithm is identical — alternate split axis cycles through all N dimensions.

**Required operations:**
- `buildTree(points: [Point4D])`
- `rangeSearch(center: Point4D, radius: Double) -> [Point4D]`
- `kNearestNeighbors(to: Point4D, k: Int) -> [Point4D]`

The descriptor search uses `rangeSearch` with a tolerance radius (typically 0.01–0.02 in normalised descriptor space).

---

### 3. TAN Projection (Swift)

**File:** `Sources/AstrophotoKit/Platesolver/TANProjection.swift`

Implements gnomonic (TAN) projection between spherical (RA/Dec) and plane (xi, eta) coordinates. Used both during index loading (step 4 above) and during WCS fitting.

**Forward projection** (RA/Dec → xi/eta, relative to a reference point RA0/Dec0):
```
xi  = cos(dec)·sin(ra − ra0) / [sin(dec0)·sin(dec) + cos(dec0)·cos(dec)·cos(ra − ra0)]
eta = [cos(dec0)·sin(dec) − sin(dec0)·cos(dec)·cos(ra − ra0)] / [sin(dec0)·sin(dec) + cos(dec0)·cos(dec)·cos(ra − ra0)]
```

**Inverse projection** (xi/eta → RA/Dec):
```
dec = atan((cos(dec0) − eta·sin(dec0)) / sqrt(xi² + (cos(dec0)·eta·sin(dec0) + sin(dec0))²... [standard formula]
ra  = ra0 + atan2(xi, cos(dec0) − eta·sin(dec0))
```

These are ~30 lines of Swift using only `Foundation` math functions.

---

### 4. WCS Fitter

**File:** `Sources/AstrophotoKit/Platesolver/WCSFitter.swift`

Given a set of matched pairs `(pixel_x, pixel_y) ↔ (ra, dec)`, derives the WCS parameters.

**Algorithm:**
1. Make an initial guess for the field centre (median pixel → median RA/Dec from the matched pairs, or use the barycentre of the image).
2. Project all catalog RA/Dec to gnomonic (xi, eta) relative to the initial centre.
3. Set up the linear system:
   ```
   xi  = CD1_1·(x − CRPIX1) + CD1_2·(y − CRPIX2)
   eta = CD2_1·(x − CRPIX1) + CD2_2·(y − CRPIX2)
   ```
   Solve for CD matrix elements and CRPIX using least squares. With ≥3 pairs this is over-determined; use normal equations (same `solve4x4` infrastructure).
4. Refine CRVAL (the sky coordinate of the reference pixel) by back-projecting CRPIX.
5. Optionally iterate with RANSAC to reject outlier pairs.

**Output:** `WCSSolution` struct containing `crpix1/2`, `crval1/2`, `cd1_1`, `cd1_2`, `cd2_1`, `cd2_2`, `rmse` (arcsec).

**Minimum matches required:** 3 pairs for a unique solution; 6+ recommended for RANSAC robustness.

---

### 5. wcslib Integration (CWCSLib)

**Directory:** `Sources/CWCSLib/`

Follows the exact same pattern as `Sources/CCFITSIO/`.

**`shim.h`:**
```c
#include <wcslib/wcs.h>
#include <wcslib/wcshdr.h>
#include <wcslib/wcsfix.h>
```

**`module.modulemap`:**
```
module CWCSLib [system] {
    header "shim.h"
    link "wcs"
    export *
}
```

**`Package.swift`** changes: add `CWCSLib` system library target; add it as a dependency of `AstrophotoKit`.

**Prerequisites:** `brew install wcslib` (depends on cfitsio which is already installed).

wcslib is used for:
- Coordinate conversions (pixel ↔ RA/Dec) after solving, using a validated `wcsprm` struct
- Writing well-formed WCS FITS header cards via `wcshdo()`
- Validation of the solved WCS

---

### 6. WCS FITS Header Writer

**File:** `Sources/AstrophotoKit/Platesolver/WCSWriter.swift`

Writes standard WCS keywords to a FITS header after solving:

```
CTYPE1  = 'RA---TAN'
CTYPE2  = 'DEC--TAN'
CRPIX1  = <reference pixel x>
CRPIX2  = <reference pixel y>
CRVAL1  = <RA at reference pixel, degrees>
CRVAL2  = <Dec at reference pixel, degrees>
CD1_1   = <CD matrix element>
CD1_2   = <CD matrix element>
CD2_1   = <CD matrix element>
CD2_2   = <CD matrix element>
WCSSOLVE= 'AstrophotoKit'
WCSNSTAR= <number of matched stars>
WCSRMSE = <fit RMS in arcsec>
```

Uses cfitsio (`fits_update_key`) via the existing `CCFITSIO` module, keeping the dependency on wcslib optional for header writing.

---

### 7. Plate Solver Processor

**File:** `Sources/AstrophotoKit/Processors/PlatesolveProcessor.swift`

Conforms to `Processor`. Wires all components together.

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `index_path` | string | required | Path to astrometry.net index file (or directory of files) |
| `scale_low` | double | 0.5 | Lower bound of pixel scale (arcsec/px) |
| `scale_high` | double | 5.0 | Upper bound of pixel scale (arcsec/px) |
| `ra_hint` | double | nil | Approximate RA centre (degrees), optional |
| `dec_hint` | double | nil | Approximate Dec centre (degrees), optional |
| `search_radius` | double | 180 | Search radius around hint (degrees) |
| `max_stars` | int | 50 | Max stars to use from detection |
| `min_matches` | int | 6 | Minimum matched pairs required |

**Inputs:** `input_frame` (Frame)
**Outputs:** `solved_frame` (Frame with WCS in header), `wcs_solution` (TableData with solution parameters)

**Pipeline ID:** `plate_solve`

---

### 8. Index Selection Logic

For a given image, the correct index scale series is determined by the expected pixel scale (arcsec/px) and the image size. Each astrometry.net index file covers a specific angular scale range.

| Series | Scale range | Typical use |
|---|---|---|
| index-4107 to 4119 | 0.3–2° | Long focal length (1000mm+) |
| index-4200 to 4219 | 2–20° | Medium focal length (200–500mm) |
| index-5200 series | Full sky | Very wide field |

The `IndexLoader` should read the `SCALE_U` and `SCALE_L` FITS header keywords from each index and only load files whose scale range overlaps the expected pixel scale × image dimension.

---

## Testing Strategy

1. **Unit tests for TAN projection** — compare against known RA/Dec↔pixel pairs from a solved reference frame.
2. **Unit tests for WCS fitting** — synthesise matched pairs from a known WCS, verify recovered parameters match to <0.01%.
3. **Integration test for index loading** — load a real index file, verify star count and quad count match header metadata.
4. **End-to-end test** — run the full `plate_solve` pipeline on a reference frame with a known solution; verify `CRVAL1/2` match to within 1 arcsec.
5. **Sparse field test** — frames with fewer than 15 detected stars.

---

## Dependencies Summary

| Dependency | Status | Action |
|---|---|---|
| cfitsio | Installed (4.6.3_1) | Already wired as `CCFITSIO` |
| wcslib | Not installed | `brew install wcslib`; add `Sources/CWCSLib/` module |
| astrometry.net index files | Not present | User downloads appropriate scale series |

---

## Open Questions

- Should the index files be user-managed (configured by path) or bundled with a download helper in the CLI?
- Do we need SIP distortion support immediately, or is a linear TAN solution sufficient for v1?
- Should `plate_solve` write the WCS back to the original archive entry, or only to the output frame?
- Multi-index support: should the solver try multiple index files automatically, or require an explicit file?
