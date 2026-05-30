---
layout: article
title: "Working with Calibration Frames in the Archive"
date: 2026-05-30 00:00:00 +0000
series: "Design"
series_order: 5
categories: astrophotography calibration archive design
published: true
---

## Overview

AstrophotoKit distinguishes two kinds of calibration frames: **source frames** (individual raw exposures taken by the camera) and **master frames** (stacked combinations of source frames, ready to apply to light frames). The archive tracks both and knows the difference.

Frame types in the archive:

| Type            | Description                                      |
|-----------------|--------------------------------------------------|
| `bias`          | Individual bias exposure                         |
| `masterBias`    | Stacked master bias                              |
| `dark`          | Individual dark exposure                         |
| `masterDark`    | Stacked master dark                              |
| `darkFlat`      | Individual dark flat exposure                    |
| `masterDarkFlat`| Stacked master dark flat                         |
| `flat`          | Individual flat exposure                         |
| `masterFlat`    | Stacked master flat                              |

## FITS Keywords

AstrophotoKit writes two FITS header keywords to identify calibration frames:

- **`IMAGETYP`** — standard de-facto convention, set to one of the commonly understood values: `Bias Frame`, `Dark Frame`, `Flat Field`, `Dark Flat`. Other software that understands `IMAGETYP` can read these without modification.
- **`ISMASTER = T`** — custom AstrophotoKit keyword, written only on master calibration stacks. When AstrophotoKit reads a FITS file back, the combination of `IMAGETYP` and `ISMASTER` determines the archive frame type (e.g. `IMAGETYP = 'Dark Frame'` + `ISMASTER = T` → `masterDark`).

This means master frames remain interoperable with other astronomy software while being correctly identified within AstrophotoKit.

Alternative `IMAGETYP` spellings are also recognized on import: `Bias`, `Zero`, `Offset` are all treated as bias; `Dark`, `Flat Frame`, `Flat`, `Dark Flat`, `DarkFlat` are recognized for their respective types.

## Querying Calibration Frames

### CLI

```bash
# All calibration frames, grouped by type
ap-archive calibration

# Raw source darks only, near -10 °C (±2 °C)
ap-archive calibration --scope source --type dark --temp-center -10

# All master stacks
ap-archive calibration --scope masters

# Flats from a specific date range
ap-archive calibration --type flat --from 2026-01-01 --to 2026-01-31

# Calibration frame sets only
ap-archive calibration --scope framesets
```

### MCP / AI assistant

Use the `archive_calibration_frames` tool:

```json
{ "scope": "all" }
{ "scope": "source", "type": "dark", "temp_center": -10, "temp_tolerance": 3 }
{ "scope": "masters" }
{ "type": "flat", "from_date": "2026-01-01", "to_date": "2026-01-31" }
{ "scope": "framesets", "type": "dark" }
```

### Library API

`AstrophotoArchiveKit` exposes the calibration query directly on `Archive`:

```swift
// All calibration frames
let all = try await archive.calibrationFrames()

// Source darks near -10 °C
let darks = try await archive.calibrationFrames(
    scope: .source,
    type: .dark,
    temperatureRange: -12...(-8)
)

// Master flats in January 2026
let flats = try await archive.calibrationFrames(
    scope: .masters,
    type: .flat,
    dateRange: DateInterval(start: jan1, end: jan31)
)

// Calibration frame sets
let sets = try await archive.calibrationFrameSets()
let darkSets = try await archive.calibrationFrameSets(type: .dark)
```

`FrameQuery.forCalibration(scope:type:temperatureRange:dateRange:camera:)` is also available for building custom queries before passing them to `archive.frames(matching:)`.

## Calibration Pipelines

The following pipelines produce master calibration frames:

| Pipeline               | Input                          | Output           |
|------------------------|--------------------------------|------------------|
| `bias_calibration`     | Bias source frames             | `masterBias`     |
| `dark_calibration`     | Dark source frames + masterBias| `masterDark`     |
| `darkflat_calibration` | Dark flat source frames        | `masterDarkFlat` |
| `flat_calibration`     | Flat source frames + masterDarkFlat | `masterFlat` |
| `calibrate_lights`     | Light frames + masterDark + masterFlat | Calibrated lights |

Pipeline results are auto-archived with the correct `IMAGETYP` and `ISMASTER` keywords.

## Compatibility Checks

When applying calibration frames, AstrophotoKit validates compatibility with the target frames and reports problems:

| Condition | Severity |
|---|---|
| Gain mismatch (>0.5 difference) | **Error** — pipeline stops |
| Offset mismatch (>5 ADU) | Warning |
| CCD temperature mismatch (>5 °C) for darks | Warning |
| Exposure time mismatch (>5 %) for darks | Warning |
| Filter mismatch for flats | Warning |
| Flat older than 24 h from lights | Warning |
| Uncooled camera, frames >12 h apart | Warning |
