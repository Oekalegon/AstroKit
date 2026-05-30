---
layout: article
title: "Calibration Frame Types and Archive Integration"
date: 2026-05-30 00:00:00 +0000
series: "Design"
series_order: 5
categories: astrophotography calibration archive design
published: true
---

## Frame Types

AstrophotoKit distinguishes two kinds of calibration frames: **source frames** (individual raw exposures taken by the camera) and **master frames** (stacked combinations of source frames, ready to apply to light frames). The archive tracks both and knows the difference.

| Type             | Description                                       |
|------------------|---------------------------------------------------|
| `bias`           | Individual bias exposure                          |
| `masterBias`     | Stacked master bias                               |
| `dark`           | Individual dark exposure                          |
| `masterDark`     | Stacked master dark                               |
| `darkFlat`       | Individual dark flat exposure                     |
| `masterDarkFlat` | Stacked master dark flat                          |
| `flat`           | Individual flat exposure                          |
| `masterFlat`     | Stacked master flat                               |

## FITS Keywords

AstrophotoKit writes two FITS header keywords to identify calibration frames:

- **`IMAGETYP`** — de-facto standard, set to one of the commonly understood values: `Bias Frame`, `Dark Frame`, `Flat Field`, `Dark Flat`. Other software that understands `IMAGETYP` can read these without modification.
- **`ISMASTER = T`** — custom AstrophotoKit keyword, written only on master calibration stacks. When AstrophotoKit reads a FITS file back, the combination of `IMAGETYP` and `ISMASTER` determines the archive frame type — e.g. `IMAGETYP = 'Dark Frame'` + `ISMASTER = T` → `masterDark`.

This means master frames remain interoperable with other astronomy software while being correctly identified within AstrophotoKit.

Alternative `IMAGETYP` spellings are recognized on import: `Bias`, `Zero`, `Offset` → bias; `Dark`; `Flat Frame`, `Flat` → flat; `Dark Flat`, `DarkFlat` → darkFlat.

## Calibration Pipelines

The following pipelines produce master calibration frames. Pipeline results are auto-archived with the correct `IMAGETYP` and `ISMASTER` keywords.

| Pipeline               | Input                                       | Output            |
|------------------------|---------------------------------------------|-------------------|
| `bias_calibration`     | Bias source frames                          | `masterBias`      |
| `dark_calibration`     | Dark source frames + `masterBias`           | `masterDark`      |
| `darkflat_calibration` | Dark flat source frames                     | `masterDarkFlat`  |
| `flat_calibration`     | Flat source frames + `masterDarkFlat`       | `masterFlat`      |
| `calibrate_lights`     | Light frames + `masterDark` + `masterFlat`  | Calibrated lights |

## Compatibility Checks

When applying calibration frames, AstrophotoKit validates compatibility and reports problems:

| Condition | Severity |
|---|---|
| Gain mismatch > 0.5 | **Error** — pipeline stops |
| Offset mismatch > 5 ADU | Warning |
| CCD temperature mismatch > 5 °C (darks) | Warning |
| Exposure time mismatch > 5 % (darks) | Warning |
| Filter mismatch (flats) | Warning |
| Flat more than 24 h from lights | Warning |
| Uncooled camera, frames more than 12 h apart | Warning |

## Library API

`AstrophotoArchiveKit` exposes calibration queries directly on `Archive`:

```swift
// All calibration frames
let all = try await archive.calibrationFrames()

// Source darks near -10 °C
let darks = try await archive.calibrationFrames(
    scope: .source,
    type: .dark,
    temperatureRange: -12...(-8)
)

// Master flats in a date range
let flats = try await archive.calibrationFrames(
    scope: .masters,
    type: .flat,
    dateRange: DateInterval(start: sessionStart, end: sessionEnd)
)

// All calibration frame sets
let sets = try await archive.calibrationFrameSets()

// Dark frame sets only
let darkSets = try await archive.calibrationFrameSets(type: .dark)
```

`FrameQuery.forCalibration(scope:type:temperatureRange:dateRange:camera:)` is also available for building a `FrameQuery` to pass to `archive.frames(matching:)` directly.

For CLI and MCP usage, see [ap-archive.md](../ap-archive.md).
