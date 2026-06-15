# ap-archive — AstrophotoKit Archive CLI

`ap-archive` manages a local FITS archive: ingests frames, indexes their metadata in SQLite, and lets you query by object, coordinates, frame type, filter, date, processing level, and rejection status.

## Installation

```bash
swift build -c release --product ap-archive
cp .build/release/ap-archive /usr/local/bin/ap-archive
```

Or use the installer (installs `ap`, `ap-archive`, and `astrokit-mcp` in one step):

```bash
python3 install.py
```

## Archive location

All commands read the archive root from the `ASTROARCHIVE_PATH` environment variable, or from the `--archive-path` flag.

```bash
export ASTROARCHIVE_PATH=~/AstroArchive
```

The archive root contains:
- `archive.db` — SQLite database with frame metadata and spatial index
- FITS files organised into subfolders by object, date, type, and filter

---

## Commands

### `ap-archive add`

Adds one or more FITS files to the archive. Reads metadata automatically from FITS headers (`OBJECT`, `RA`, `DEC`, `IMAGETYP`, `FILTER`, `INSTRUME`, `DATE-OBS`, `EXPTIME`, `GAIN`, `CCD-TEMP`, …).

```
ap-archive add <path> [--recursive] [--json]
```

| Flag | Description |
|------|-------------|
| `--recursive` | Recurse into subdirectories (when path is a directory) |
| `--json` | Print results as JSON |

Files are always copied into the archive folder hierarchy (`<root>/<object>/<date>/<type>/<filter>/`). The original file is left untouched.

**Examples:**

```bash
# Add a single file:
ap-archive add ~/lights/M51_Ha_300s.fits

# Add an entire directory:
ap-archive add ~/lights/

# Add all FITS files in a directory tree:
ap-archive add ~/lights/ --recursive

# JSON output for scripting:
ap-archive add ~/lights/ --json
```

**Example output:**

```
Added 5 frame(s) to the archive.
  light [Hɑ] 300s M51  /path/to/M51_Ha_001.fits
  light [Hɑ] 300s M51  /path/to/M51_Ha_002.fits
  ...
```

---

### `ap-archive find`

Searches the archive and lists matching frames.

```
ap-archive find [options]
```

| Option | Description |
|--------|-------------|
| `--object <name>` | Partial object name match (e.g. `M51`) |
| `--camera <name>` | Camera name (exact match) |
| `--type <types>` | Comma-separated frame types: `light,dark,flat,bias,diagnostic` |
| `--filter <filters>` | Comma-separated filters: `Hɑ,SII,OIII,R,G,B,L` |
| `--from <date>` | Start date in `YYYY-MM-DD` format |
| `--to <date>` | End date in `YYYY-MM-DD` format |
| `--level <level>` | Processing level: `raw`, `calibrated`, `stacked`, `stretched` |
| `--calibrated` | Only calibrated frames |
| `--stacked` | Only stacked frames |
| `--ra <deg>` | Cone search centre RA (degrees) |
| `--dec <deg>` | Cone search centre Dec (degrees) |
| `--radius <deg>` | Cone search radius (degrees) |
| `--limit <n>` | Maximum number of results |
| `--include-rejected` | Include rejected frames in results (by default they are hidden) |
| `--rejected-only` | Show only rejected frames |
| `--max-fwhm <px>` | Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded. |
| `--min-stars <n>` | Only frames with at least this many detected stars. Frames without quality data are excluded. |
| `--max-background-noise <v>` | Only frames with background noise ≤ this value (0–1). Frames without quality data are excluded. |
| `--max-eccentricity <v>` | Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded. |
| `--json` | Print results as JSON |

**Examples:**

```bash
# All light frames of M51:
ap-archive find --object M51 --type light

# Hɑ and SII lights taken in 2024:
ap-archive find --type light --filter Hɑ,SII --from 2024-01-01 --to 2024-12-31

# All frames within 1° of RA=202.47°, Dec=+47.20° (M51):
ap-archive find --ra 202.47 --dec 47.20 --radius 1.0

# Most recent 20 stacked frames:
ap-archive find --stacked --limit 20

# Review all rejected frames:
ap-archive find --rejected-only

# Only frames with good seeing (FWHM ≤ 4 px, ≥ 150 stars, eccentricity ≤ 0.4):
ap-archive find --object M51 --type light --max-fwhm 4 --min-stars 150 --max-eccentricity 0.4
```

---

### `ap-archive recent`

Lists the most recently archived frames, newest first. Useful for reviewing what was just added or produced by a pipeline run.

```
ap-archive recent [-c <count>] [--json]
```

| Option | Description |
|--------|-------------|
| `-c`, `--count <n>` | Number of frames to show (default: 15); 0 or negative shows all |
| `--json` | Print results as JSON |

**Examples:**

```bash
# Show the 15 most recently archived frames:
ap-archive recent

# Show the 5 most recently archived frames:
ap-archive recent -c 5

# JSON output for scripting:
ap-archive recent --json
```

**Example output:**

```
Recently archived frames (15):

ID                                    Added at          Type      Filter    Exposure  File
--------------------------------------------------------------------------------------------------------------
A3F2B1C0-1234-5678-ABCD-EF0123456789  2026-05-26 14:32  light     Hɑ           300s  M51_Ha_300s_018.fits
B4E3D2F1-1234-5678-ABCD-EF0123456789  2026-05-26 14:32  light     Hɑ           300s  M51_Ha_300s_017.fits
C5F4E3D2-1234-5678-ABCD-EF0123456789  2026-05-25 22:10  stacked   Hɑ              -  stacked.fits
…
```

> The list is sorted by **archive ingestion time** (`Added at`), not by observation date. This means a freshly auto-archived pipeline result appears at the top even if the underlying light frames are weeks old.

---

### `ap-archive reject`

Marks a frame as rejected so it is excluded from all processing queries, or clears that flag.

```
ap-archive reject <id> [--reason "..."] [--undo]
```

| Flag | Description |
|------|-------------|
| `--reason <text>` | Optional description of why the frame was rejected |
| `--undo` | Clear the rejection flag (un-reject the frame) |

Rejected frames are **silently excluded** from `find` results and from any processing pipeline that queries the archive. They remain in the database and can be reviewed at any time with `find --rejected-only`.

**Examples:**

```bash
# Reject a frame due to telescope movement:
ap-archive reject A3F2B1C0-... --reason "telescope moved mid-exposure"

# Review all rejected frames:
ap-archive find --rejected-only

# Review all frames including rejected ones:
ap-archive find --include-rejected

# Un-reject a frame:
ap-archive reject A3F2B1C0-... --undo
```

---

### `ap-archive list-objects`

Lists all objects in the archive with their frame counts.

```
ap-archive list-objects [--json]
```

**Example output:**

```
Objects in archive (4):

  M31         23 frame(s)
  M51         15 frame(s)
  NGC 6992    8 frame(s)
  NGC 7000    12 frame(s)
```

---

### `ap-archive stats`

Shows archive statistics.

```
ap-archive stats [--json]
```

**Example output:**

```
Archive Statistics
  Archive path: /Users/don/AstroArchive

  Total objects: 4
  Total frames:  58

  Frames by type:
    bias          4
    dark          8
    flat          4
    light         42
      Hɑ          18
      OIII        12
      SII         12

  Disk used:      24.3 GB
  Disk available: 1.2 TB
```

---

### `ap-archive frameset`

Manages frame sets — named, homogeneous collections of archived frames used as inputs to processing pipelines.

A frame set requires all member frames to share the same **type** (light, dark, flat, bias, or diagnostic) and the same **processing level**. Optical filter must also be uniform — use `--force` to allow mixed filters. Shared properties (object, camera, exposure, temperature, date span, pixel scale, position angle) are recorded automatically; any property that differs across members is left blank.

After creation the command always prints an inspection report so you can verify the result.

#### `ap-archive frameset create`

Creates a frame set from frames matching a query. Rejected frames are always excluded.

```
ap-archive frameset create [options]
```

| Option | Description |
|--------|-------------|
| `--name <name>` | Name for the frame set (auto-generated if omitted) |
| `--type <type>` | **Required.** Frame type: `light`, `dark`, `flat`, `bias`, `diagnostic` |
| `--object <name>` | Partial object name match |
| `--filter <filter>` | Optical filter |
| `--camera <name>` | Camera name (exact match) |
| `--from <date>` | Start date `YYYY-MM-DD` |
| `--to <date>` | End date `YYYY-MM-DD` |
| `--level <level>` | Processing level: `raw`, `calibrated`, `stacked`, `stretched` |
| `--calibrated` | Only calibrated frames |
| `--temp-center <°C>` | Centre temperature for dark frame grouping |
| `--temp-tolerance <°C>` | Temperature tolerance ±°C (default 2.0) |
| `--max-fwhm <px>` | Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded. |
| `--min-stars <n>` | Only frames with at least this many detected stars. Frames without quality data are excluded. |
| `--max-background-noise <v>` | Only frames with background noise ≤ this value (0–1). Frames without quality data are excluded. |
| `--max-eccentricity <v>` | Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded. |
| `--force` | Allow mixed optical filters (stored as comma-separated list) |
| `--dry-run` | Show the inspection report without creating the frame set |
| `--json` | Print result as JSON |

**Examples:**

```bash
# Preview which frames would be included (dry-run):
ap-archive frameset create --type light --object M51 --filter Hɑ --dry-run

# All Hɑ light frames of M51:
ap-archive frameset create --type light --object M51 --filter Hɑ

# Named frameset with a specific camera and date range:
ap-archive frameset create --name "M51 Hɑ 2024" \
  --type light --object M51 --filter Hɑ \
  --from 2024-01-01 --to 2024-12-31 \
  --camera "ZWO ASI294MC Pro"

# Dark frames within ±2°C of -10°C:
ap-archive frameset create --type dark --temp-center -10 --temp-tolerance 2

# Allow frames from multiple filters (e.g. broadband LRGB):
ap-archive frameset create --type light --object M51 --force

# Only frames with good seeing — FWHM ≤ 5 px, ≥ 100 stars, eccentricity ≤ 0.4 (quality-first stacking):
ap-archive frameset create --type light --object "NGC 6910" --filter SII --max-fwhm 5 --min-stars 100 --max-eccentricity 0.4
```

> **Tip:** Run `ap run star_detection --input <file>` on your light frames before creating a quality-filtered frame set. The pipeline automatically writes star count, FWHM, eccentricity, and background noise back to each archived frame so the quality filters have data to work with. Frames without quality data are **excluded** from results whenever a quality filter is active.

**Example output (dry-run):**

```
Dry-run inspection — 18 frame(s) matched
────────────────────────────────────────────────────
  Frame type:    ✓ light (18)
  Filter:        ✓ Hɑ (18)
  Processing:    ✓ raw (18)
  Object:        ✓ M51 (18)
  Camera:        ✓ ZWO ASI294MC Pro (18)
  Pixel scale:   ✓ 1.240 "/px (18)
  Focal length:  ✓ 800 mm (18)
  Pos. angle:    ✓ 0.0° (18)
  Date span:     2024-03-15 – 2024-11-22 (252 day(s))
  Temperature:   -10.0 – -9.8 °C (mean -9.9)

  ✓ Ready to create.

Frames (18):
  UUID                                  Object          Filter    Exposure  Date
  ────────────────────────────────────────────────────────────────────────
  a1b2c3d4-...                          M51             Hɑ            300s  2024-03-15
  …
```

#### `ap-archive frameset list`

Lists all frame sets with their member counts.

```
ap-archive frameset list [--json]
```

#### `ap-archive frameset show`

Shows full details of a frame set and a table of all member frames with their key properties.

```
ap-archive frameset show <id> [--json]
```

**Example output:**

```
Frame Set  A3F2B1C0-1234-5678-ABCD-EF0123456789
────────────────────────────────────────────────────────────
  Name:          M51 Hɑ 2024
  Type:          light
  Level:         raw
  Frames:        18
  Object:        M51
  Filter:        Hɑ
  Camera:        ZWO ASI294MC Pro
  Exposure:      300 s
  Temperature:   -10.0 – -9.8 °C (mean -9.9)
  Pixel scale:   1.240 "/px
  Focal length:  800 mm
  Date span:     2024-03-15 – 2024-11-22
  Created:       2026-05-25T10:00:00Z

Members (18):
  UUID                                  Object          Filter    Exposure  Date
  ────────────────────────────────────────────────────────────────────────────────
  a1b2c3d4-xxxx-xxxx-xxxx-xxxxxxxxxxxx  M51             Hɑ            300s  2024-03-15
  b2c3d4e5-xxxx-xxxx-xxxx-xxxxxxxxxxxx  M51             Hɑ            300s  2024-03-16
  …
```

#### `ap-archive frameset add`

Adds frames to an existing frame set.

```
ap-archive frameset add <set-id> <frame-id...> [--force] [--json]
```

Each frame must match the set's **type**, **processing level**, and **optical filter**, and — for sets created since the criteria were persisted — the full query the set was created with (object, camera, date range, temperature, quality filters). This keeps a set consistent with what `frameset create` originally selected. Rejected frames are refused; frames already in the set are skipped.

When the set was created with `--max-fwhm` or `--max-eccentricity`, frames exceeding those thresholds are added but marked **excluded**, exactly as on creation.

| Option | Description |
|--------|-------------|
| `--force` | Skip the filter and creation-criteria checks. Frame type and processing level must still match. New filters are merged into the set's comma-separated filter list. |
| `--json` | Print the updated frame set as JSON |

```bash
# Add two newly archived frames to an existing set:
ap-archive frameset add a3f2b1c0-... 1111aaaa-... 2222bbbb-...

# Add a frame from a different filter (broadband LRGB set):
ap-archive frameset add a3f2b1c0-... 3333cccc-... --force
```

After the change, the set's shared properties, date span, temperature statistics, and quality medians are recomputed from the new membership.

#### `ap-archive frameset remove`

Removes frames from a frame set. The frames themselves stay in the archive.

```
ap-archive frameset remove <set-id> <frame-id...> [--json]
```

Frames that are not members of the set are skipped (with a warning). Removing **all** remaining members is refused — use `frameset delete` to delete the whole set instead. Aggregated set properties are recomputed after the removal.

#### `ap-archive frameset delete`

Deletes a frame set. Member frames are **not** removed from the archive.

```
ap-archive frameset delete <id>
```

---

### `ap-archive info`

Shows all stored information for a single archive frame, including provenance if the frame was produced by a pipeline run.

```
ap-archive info <id> [--json]
```

| Flag | Description |
|------|-------------|
| `--json` | Print result as JSON |

**Example output:**

```
Frame  A3F2B1C0-1234-5678-ABCD-EF0123456789
────────────────────────────────────────────────────────────
  Type:              light
  Object:            M51
  Filter:            Hɑ
  Exposure:          300 s
  Date:              2024-03-15T22:10:00Z

  Camera:            ZWO ASI294MC Pro
  Gain:              100
  Temperature:       -10.0 °C

  RA / Dec:          202.4700° / 47.1952°  (J2000)
  Pixel scale:       1.240 "/px
  Focal length:      800 mm
  Size:              6248 × 4176  (16-bit)

  Processing:        raw  [calibrated: ✗  stacked: ✗  stretched: ✗]
  Added at:          2026-05-25T10:00:00Z
  File:              /Users/…/AstroArchive/M51/2024-03-15/light/Hɑ/M51_Ha_300s_001.fits

Quality metrics
────────────────────────────────────────────────────────────
  Stars:             312
  FWHM:              3.85 px
  Eccentricity:      0.312
  Bg. noise:         0.0028

Display stretch
────────────────────────────────────────────────────────────
  Norm black:        0.0000
  Norm white:        0.1000
  Slider black:      0.0000
  Slider white:      0.0400

Provenance
────────────────────────────────────────────────────────────
  Run ID:            D1E2F3A4-5678-9ABC-DEF0-123456789ABC
  Pipeline:          frame_stacking
  Run at:            2026-05-25T10:00:00Z
  Parameters:        method=average  normalisation=multiplicative
  Inputs:
    input_frames[0]  /Users/…/lights/M51_Ha_001.fits  [archive: B4E3D2F1-...]
    input_frames[1]  /Users/…/lights/M51_Ha_002.fits  [archive: C5F4E3A2-...]
    …
```

The Provenance section is shown only for frames that were archived automatically by `ap run` or `run_pipeline` (MCP). Frames added manually with `ap-archive add` have no provenance record.

---

### `ap-archive headers`

Prints the full FITS header of an archive frame, grouped by topic (Object, Observation, Telescope & Optics, Camera, Site & Conditions, Astrometric Solution, Processing & Stacking, Quality, File Structure) with human readable names. The original FITS keyword is shown in brackets after each value. Unlike `ap-archive info`, which shows the metadata stored in the archive database, `headers` reads the FITS file itself.

```bash
ap-archive headers F6AFAADD-5097-4976-970E-358F6249E7ED
```

```
Frame: F6AFAADD-5097-4976-970E-358F6249E7ED
File:  /path/in/archive/navi_result_….fits

Object
──────────
  Object           NGC 6910  [OBJECT]
  Right Ascension  305.8069 °  [RA]
  Declination      40.77605 °  [DEC]

Observation
───────────────
  Observation Start  2026-05-01T23:23:15Z  [DATE-OBS]
  Exposure Time      3600 s  [EXPTIME]
  ...
```

Add `--json` for machine-readable output: the same grouped entries (original keyword, human readable name, raw value, display value, unit) plus `frame_id`, `file`, and the complete original header as a flat `header` object. For arbitrary FITS files outside the archive, use `ap headers <file>` instead — both commands share the same grouping and output format.

---

### `ap-archive cp`

Exports a copy of a frame or an entire frame set out of the archive to a local path. The original stays in the archive.

```
ap-archive cp <id> <destination>
```

`<id>` can be either a frame UUID or a frame set UUID — the command auto-detects which.

**Destination path rules** (same as Unix `cp`):

| Destination | Behaviour |
|-------------|-----------|
| Existing directory | Copy into it, preserving the original filename |
| Non-existent path (single frame) | Write the file at exactly that path (parent directories are created automatically) |
| Non-existent path (frame set) | Create that directory and copy all member frames into it |
| Existing file | Error — remove the file first |

**Examples:**

```bash
# Copy one frame into an existing directory:
ap-archive cp A3F2B1C0-... ~/Desktop/exports/

# Copy one frame with a new name:
ap-archive cp A3F2B1C0-... ~/Desktop/M51_Ha_best.fits

# Copy an entire frame set to a new directory:
ap-archive cp B4E3D2F1-... ~/Desktop/M51_Ha_lights/
```

**Example output (single frame):**

```
Copied A3F2B1C0-1234-5678-ABCD-EF0123456789  →  /Users/don/Desktop/exports/M51_Ha_300s_001.fits
```

**Example output (frame set):**

```
Copied 18 frame(s) from 'M51 Hɑ 2024' to /Users/don/Desktop/M51_Ha_lights.
```

---

### `ap-archive stretch`

Saves or clears the display stretch for an archived frame. The stretch is stored as normalized
[0, 1] black and white points relative to the frame's full tonal range, making it independent
of bit depth and sensor gain. The underlying FITS file is **never modified** — only the archive
database is updated.

The typical workflow is to adjust the stretch interactively in Navi and press **Normalize**, which
bakes the current slider positions into the archive automatically. Use this command to set or
override the saved stretch from the command line.

```
ap-archive stretch <id> --black <value> --white <value> [--slider-black <value>] [--slider-white <value>]
ap-archive stretch <id> [--slider-black <value>] [--slider-white <value>]
ap-archive stretch <id> --reset
```

Two independent pieces of state are stored:

- **Normalization bounds** (`--black` / `--white`): the sub-range of the data that was mapped to [0, 1] when **Normalize** was pressed in Navi.
- **Slider positions** (`--slider-black` / `--slider-white`): where the black/white-point sliders currently sit within [0, 1] of the full data range. These are independent of the normalization — a white-point slider at 0.04 inside a [0, 0.1] normalization renders an effective white point of 0.004.

| Option | Description |
|--------|-------------|
| `--black <value>` | Normalization black bound in [0, 1]. Must be < `--white`. |
| `--white <value>` | Normalization white bound in [0, 1]. Must be > `--black`. |
| `--slider-black <value>` | Black-point slider in [0, 1] of the full data range. |
| `--slider-white <value>` | White-point slider in [0, 1] of the full data range. |
| `--reset` | Clear all stretch and slider state, reverting to the full image range. |

**Examples:**

```bash
# Set normalization to bottom 10 % and place the white slider at 0.04 (4 % of data, 40 % of the stretch)
ap-archive stretch A3F2B1C0-... --black 0.0 --white 0.1 --slider-black 0.0 --slider-white 0.04

# Update only the slider positions without changing the saved normalization
ap-archive stretch A3F2B1C0-... --slider-white 0.07

# Clear everything
ap-archive stretch A3F2B1C0-... --reset
```

---

### `ap-archive remove`

Removes a frame from the archive by its UUID. Optionally deletes the FITS file from disk.

```
ap-archive remove <id> [--delete-file]
```

| Flag | Description |
|------|-------------|
| `--delete-file` | Also delete the FITS file from disk |

**Example:**

```bash
ap-archive remove A3F2B1C0-... --delete-file
```

---

## How the archive works

### Metadata extraction

When a file is added, `ap-archive` reads its FITS header to extract:

| FITS keyword(s) | Field |
|-----------------|-------|
| `OBJECT` | Object name |
| `RA`, `OBJCTRA` | Right ascension (degrees) |
| `DEC`, `OBJCTDEC` | Declination (degrees) |
| `IMAGETYP`, `FRAME` | Frame type (light/dark/flat/bias/diagnostic) |
| `FILTER` | Filter name |
| `INSTRUME` | Camera |
| `FOCALLEN` | Focal length (mm) |
| `CCD-TEMP`, `CCDTEMP` | Sensor temperature (°C) |
| `DATE` | File creation timestamp (used for deduplication) |
| `DATE-OBS`, `DATE-BEG` | Observation timestamp |
| `EXPTIME`, `EXPOSURE` | Exposure time (s) |
| `GAIN` | Camera gain |
| `OFFSET`, `PEDESTAL` | Camera offset |

Processing level is inferred from `IMAGETYP` and custom keywords (`CALIBRAT`, `STACKED`, `STRETCHD`).

### Quality metrics

Four per-frame quality metrics are stored alongside the standard metadata:

| Field | FITS keyword | Description |
|-------|-------------|-------------|
| Stars | `NSTARS` | Number of detected stars |
| FWHM | `MEDFWHM` | Median FWHM in pixels (average of major and minor axes) |
| Eccentricity | `MEDECCEN` | Median star eccentricity (0=circular; lower is rounder and indicates better tracking and focus) |
| Bg. noise | `BACKNOIS` | Background noise, normalised 0–1 |

Metrics can be populated in two ways:

1. **Automatically by `ap run`** — after any pipeline run, `ap` back-updates the quality metrics for each archived input frame. Pipelines that produce a per-frame registration table (`frame_registration`, `frame_stacking`) update each frame individually. Pipelines with a global summary table (`star_detection`, `optical_quality`, `autofocus_focused`) update all input frames with the aggregate values.

2. **From FITS headers on `add`** — if the file already contains `NSTARS`, `MEDFWHM`, `MEDECCEN`, or `BACKNOIS` headers (written by compatible tools or a previous pipeline run), those values are read automatically when the file is added to the archive.

Metrics are populated progressively — a frame can be archived first and enriched with quality data later. When a quality filter (`--max-fwhm`, `--min-stars`, `--max-background-noise`, `--max-eccentricity`) is active, frames without quality data for that field are **excluded** from results, because there is no way to verify they meet the threshold.

**Workflow:**

```bash
# 1. Add your light frames to the archive:
ap-archive add ~/lights/NGC6910_SII/ --recursive

# 2. Run star_detection on each frame — this writes quality metrics back:
ap run star_detection --input ~/lights/NGC6910_SII/

# 3. Create a frameset containing only the sharpest frames:
ap-archive frameset create --object "NGC 6910" --filter SII --max-fwhm 5 --min-stars 100
```

### Deduplication

Each frame is assigned a content signature based on its **file creation date** (`DATE` header), frame type, filter, and exposure time. Adding the same file twice is silently ignored — the second insert returns the existing record.

The file creation date is resolved using a fallback chain:

1. `DATE` FITS header — written by `ap run` / `run_pipeline` at the moment the output file is created
2. `DATE-OBS` — used as a fallback for raw frames from capture software that do not write `DATE`
3. Filesystem creation date — last resort when neither header is present

Because each pipeline run writes a fresh `DATE` timestamp, re-running a stacking or processing pipeline with the same inputs produces a **new** archive entry rather than silently discarding the result. This lets you keep multiple processed versions of the same data (e.g. stacks with different parameters or updated algorithms).

### Coordinate search

Right ascension and declination are indexed using [HEALPix](https://healpix.sourceforge.io) at nside=64 (~55 arcmin resolution). Cone searches (`--ra`, `--dec`, `--radius`) use this index for fast spatial lookup.

### Folder structure

Files are placed under:

```
<archive-root>/<object>/<YYYY-MM-DD>/<frame-type>/<filter>/<filename>.fits
```

For example: `~/AstroArchive/M51/2024-03-15/light/Hɑ/M51_Ha_300s_001.fits`

### Provenance

When `ap run` or `run_pipeline` (MCP) produces frame outputs and `ASTROARCHIVE_PATH` is set, result frames are automatically archived with a provenance record linking them to their source run. The record captures:

- The pipeline ID and all parameters used
- Every input file path, and its archive UUID if the input was already in the archive

View provenance with `ap-archive info <id>` or `archive_get` (MCP). Frames added manually with `ap-archive add` have no provenance record.

### Schema migrations

The archive database applies schema migrations automatically on open using `PRAGMA user_version`. Existing archives upgrade safely when a new version of `ap-archive` is installed.

## Requirements

- macOS 26+
- CFITSIO installed (`brew install cfitsio`)
