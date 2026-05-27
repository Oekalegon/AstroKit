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
| `--type <types>` | Comma-separated frame types: `light,dark,flat,bias` |
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
```

---

### `ap-archive recent`

Lists the most recently archived frames, newest first. Useful for reviewing what was just added or produced by a pipeline run.

```
ap-archive recent [-c <count>] [--json]
```

| Option | Description |
|--------|-------------|
| `-c`, `--count <n>` | Number of frames to show (default: 15) |
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

A frame set requires all member frames to share the same **type** (light, dark, flat, or bias) and the same **processing level**. Optical filter must also be uniform — use `--force` to allow mixed filters. Shared properties (object, camera, exposure, temperature, date span, pixel scale, position angle) are recorded automatically; any property that differs across members is left blank.

After creation the command always prints an inspection report so you can verify the result.

#### `ap-archive frameset create`

Creates a frame set from frames matching a query. Rejected frames are always excluded.

```
ap-archive frameset create [options]
```

| Option | Description |
|--------|-------------|
| `--name <name>` | Name for the frame set (auto-generated if omitted) |
| `--type <type>` | Frame type: `light`, `dark`, `flat`, `bias` |
| `--object <name>` | Partial object name match |
| `--filter <filter>` | Optical filter |
| `--camera <name>` | Camera name (exact match) |
| `--from <date>` | Start date `YYYY-MM-DD` |
| `--to <date>` | End date `YYYY-MM-DD` |
| `--level <level>` | Processing level: `raw`, `calibrated`, `stacked`, `stretched` |
| `--calibrated` | Only calibrated frames |
| `--temp-center <°C>` | Centre temperature for dark frame grouping |
| `--temp-tolerance <°C>` | Temperature tolerance ±°C (default 2.0) |
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
```

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
  Type:              stacked
  Object:            M51
  Filter:            Hɑ
  Exposure:          5400 s

  Camera:            ZWO ASI294MC Pro
  Gain:              100

  Size:              6248 × 4176

  Processing:        stacked  [calibrated: ✗  stacked: ✓  stretched: ✗]
  Added at:          2026-05-25T10:00:00Z
  File:              /Users/…/AstroArchive/M51/stacked/Hɑ/stacked.fits

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
| `IMAGETYP`, `FRAME` | Frame type (light/dark/flat/bias) |
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
