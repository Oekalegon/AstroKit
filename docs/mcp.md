# astrokit-mcp — AstrophotoKit MCP Server

`astrokit-mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server that exposes AstrophotoKit pipelines as tools. Connect it to Claude Desktop, VS Code, or any MCP-compatible client to analyse astrophotos through conversation.

## Installation

```bash
swift build -c release --product astrokit-mcp
cp .build/release/astrokit-mcp /usr/local/bin/astrokit-mcp
```

Or use the installer (installs `ap`, `ap-archive`, and `astrokit-mcp` in one step):

```bash
python3 install.py
```

## Connecting to Claude Desktop

Add the following to your `claude_desktop_config.json` (usually at `~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "astrokit": {
      "command": "/usr/local/bin/astrokit-mcp",
      "env": {
        "ASTROARCHIVE_PATH": "/path/to/your/AstroArchive"
      }
    }
  }
}
```

Restart Claude Desktop. The sixteen tools below will be available in every conversation.

> **Archive tools** (`archive_*`) require `ASTROARCHIVE_PATH` to be set — either in the MCP server `env` block above or as a system environment variable.

## Connecting to VS Code (Claude extension)

Open your Claude Code settings (`.claude/settings.json`) and add:

```json
{
  "mcpServers": {
    "astrokit": {
      "command": "/usr/local/bin/astrokit-mcp",
      "type": "stdio",
      "env": {
        "ASTROARCHIVE_PATH": "/path/to/your/AstroArchive"
      }
    }
  }
}
```

## Available tools

Tools are grouped into two categories: **pipeline tools** for analysing FITS images, and **archive tools** for managing your FITS library.

### `list_pipelines`

Lists all registered pipelines with their IDs and descriptions.

**No arguments.**

Example response:
```
Available pipelines (9):
• autofocus-donut: Autofocus for out-of-focus images
• collimation-reflector: Mirror collimation analysis
• star_detection: Detects stars using Gaussian blur, thresholding, connected components …
```

---

### `inspect_pipeline`

Returns a pipeline's required inputs, configurable parameters, and step list.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `pipeline_id` | string | ✓ | Pipeline ID (e.g. `"star_detection"`) |

Example:
```
Pipeline: star_detection
Name: Star Detection Pipeline
Inputs (1): input_frame

Parameters:
  blur_radius [default: 3.0] — Blur radius in pixels
  threshold_value [default: 3.0] — Threshold value (sigma multiplier)
  …
```

---

### `run_pipeline`

Executes a pipeline on one or more FITS files and returns the analysis results as text.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `pipeline_id` | string | ✓ | Pipeline ID to run |
| `input_path` | string | | Absolute path to a single FITS file (single-frame pipelines) |
| `input_paths` | array | | Array of FITS file paths for multi-frame pipelines (e.g. `frame_registration`, `frame_stacking`) |
| `input_dir` | string | | Absolute path to a directory; all `.fits`/`.fit`/`.fts` files are loaded as a FrameSet (sorted by filename). Takes precedence over `input_paths`. |
| `input_name` | string | | Input slot name (auto-detected for single-input pipelines) |
| `parameters` | object | | Pipeline parameters as key-value pairs (use `inspect_pipeline` to see available parameters) |
| `output_path` | string | | File path to save the output. For stacking pipelines (e.g. `frame_stacking`) this writes a FITS file containing the stacked image (primary HDU, float32) plus a registration BINTABLE extension. For analysis pipelines (e.g. `frame_registration`) it writes the result table. |
| `output_format` | string | | `"fits"` (default) or `"csv"` (table-only output) |

**Single-frame pipeline example:**
```
run_pipeline(pipeline_id="star_detection", input_path="/data/M51.fits")
```

**Multi-frame pipeline — registration:**
```
run_pipeline(
  pipeline_id="frame_registration",
  input_dir="/data/lights/",
  output_path="/tmp/registration.fits"
)
```

**Multi-frame pipeline — stacking:**
```
run_pipeline(
  pipeline_id="frame_stacking",
  input_dir="/data/lights/",
  parameters={
    "method": "average",
    "normalisation": "multiplicative",
    "pixel_rejection": "sigma_clip",
    "rejection_low": 3.0,
    "rejection_high": 3.0
  },
  output_path="/tmp/stacked.fits"
)
```

The stacked FITS output includes these header keywords:

| Keyword | Description |
|---------|-------------|
| `IMAGETYP` | `"STACKED LIGHT"` |
| `NFRAMES` | Number of frames integrated |
| `EXPTIME` | Total integration time (s) |
| `FILTER` | Filter from the reference frame |
| `GAIN` | Camera gain from the reference frame |
| `DATE-OBS` | Earliest observation timestamp |
| `PIPELINE` | `"frame_stacking"` |
| `STCKMET` | Combine method |
| `STCKNORM` | Normalisation method |
| `STCKREJO` | Pixel rejection method |
| `STCKRJLO` / `STCKRJHI` | Rejection sigma thresholds |

**Auto-archiving:** When `ASTROARCHIVE_PATH` is set and the pipeline produces Frame outputs, result frames are automatically archived with a provenance record (pipeline ID, parameters, input file paths). A note such as `Archived result → <UUID>` is appended to the response.

**Single-frame response example:**
```
Pipeline 'star_detection' completed in 1.43s.
2 frame(s) produced, 2 table(s) produced.

Table 1 — 47 rows, columns: label, centroid_x, centroid_y, area, fwhm_major, fwhm_minor
  { label: 1, centroid_x: 512.3421, centroid_y: 401.1234, fwhm_major: 3.2100, fwhm_minor: 3.0021 }
  { label: 2, centroid_x: 234.8712, centroid_y: 189.5432, fwhm_major: 2.9876, fwhm_minor: 2.8901 }
  …

Table 2 — 1 rows, columns: median_fwhm_major, median_fwhm_minor
  { median_fwhm_major: 3.1200, median_fwhm_minor: 2.9500 }
```

---

## Archive tools

The archive tools read and write a local FITS archive backed by SQLite. Set `ASTROARCHIVE_PATH` before using them.

### `archive_add`

Adds a FITS file or directory of FITS files to the archive. Reads metadata automatically from FITS headers (`OBJECT`, `RA`, `DEC`, `IMAGETYP`, `FILTER`, `DATE-OBS`, `EXPTIME`, …).

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `path` | string | ✓ | Absolute path to a FITS file or directory |
| `recursive` | boolean | | Recurse into subdirectories (default `false`) |

Files are always copied into the archive folder hierarchy (`<root>/<object>/<date>/<type>/<filter>/`). The original file is left untouched.

Example:
```
archive_add(path="/data/lights/M51", recursive=true)
```

Response:
```
Added 5 frame(s) to the archive.
  light [Ha] 300s M51  A3F2B1C0-...
  light [Ha] 300s M51  B4E3D2F1-...
  …
```

---

### `archive_get`

Shows all stored information for a single archive frame.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | string | ✓ | Frame UUID (from `archive_find`) |

Example:
```
archive_get(id="A3F2B1C0-1234-5678-ABCD-EF0123456789")
```

Response:
```
Frame  A3F2B1C0-1234-5678-ABCD-EF0123456789
────────────────────────────────────────────────────────────
  Type:              light
  Object:            M51
  Filter:            Ha
  Exposure:          300 s

  Camera:            ZWO ASI294MC Pro
  Gain:              100
  Temperature:       -10.0 °C

  RA / Dec:          202.4700° / 47.1952°  (J2000)
  Pixel scale:       1.240 "/px
  Focal length:      800 mm
  Size:              6248 × 4176  (16-bit)

  Processing:        raw  [calibrated: ✗  stacked: ✗  stretched: ✗]
  Added at:          2026-05-25T10:00:00Z
  File:              /Users/…/AstroArchive/M51/2024-03-15/light/Ha/M51_Ha_300s_001.fits

Quality metrics
────────────────────────────────────────────────────────────
  Stars:             312
  FWHM:              3.85 px
  Eccentricity:      0.312
  Bg. noise:         0.0028

Provenance
────────────────────────────────────────────────────────────
  Run ID:            D1E2F3A4-5678-9ABC-DEF0-123456789ABC
  Pipeline:          frame_stacking
  Run at:            2026-05-25T10:00:00Z
  Parameters:        method=average  normalisation=multiplicative
  Inputs:
    input_frames[0]  /Users/…/lights/M51_Ha_001.fits  [archive: B4E3D2F1-...]
    input_frames[1]  /Users/…/lights/M51_Ha_002.fits  [archive: C5F4E3A2-...]
```

The Provenance section is shown only for frames archived automatically by `run_pipeline`. Frames added manually with `archive_add` have no provenance record.

---

### `archive_find`

Searches the archive and returns matching frames.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `object_name` | string | | Partial object name match (e.g. `"M51"`) |
| `camera` | string | | Camera name (exact match) |
| `frame_types` | array | | Frame types: `["light"]`, `["dark","flat"]`, etc. |
| `filters` | array | | Filters: `["Ha","SII"]`, `["R","G","B"]`, etc. |
| `processing_level` | string | | `"raw"`, `"calibrated"`, `"stacked"`, or `"stretched"` |
| `calibrated` | boolean | | Only calibrated frames |
| `stacked` | boolean | | Only stacked frames |
| `ra` | number | | Cone search centre RA (degrees) |
| `dec` | number | | Cone search centre Dec (degrees) |
| `radius_deg` | number | | Cone search radius (degrees) |
| `limit` | integer | | Maximum number of results |
| `include_rejected` | boolean | | Include rejected frames in results (default `false`) |
| `rejected_only` | boolean | | Return only rejected frames |
| `max_fwhm` | number | | Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded. |
| `min_stars` | integer | | Only frames with at least this many detected stars. Frames without quality data are excluded. |
| `max_background_noise` | number | | Only frames with background noise ≤ this value (0–1). Frames without quality data are excluded. |
| `max_eccentricity` | number | | Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded. |

By default, rejected frames are excluded from results — safe for pipeline use. Use `include_rejected` or `rejected_only` to surface them.

Examples:
```
archive_find(object_name="M51", frame_types=["light"], filters=["Ha"])
archive_find(ra=202.47, dec=47.20, radius_deg=1.0)
archive_find(stacked=true, limit=20)
archive_find(rejected_only=true)
```

---

### `archive_list_objects`

Lists all objects in the archive with their frame counts. No arguments.

Response:
```
Objects in archive (4):
  M31: 23 frame(s)
  M51: 15 frame(s)
  NGC 6992: 8 frame(s)
  NGC 7000: 12 frame(s)
```

---

### `archive_stats`

Returns archive statistics: frame counts by type and filter, disk usage. No arguments.

Response:
```
Archive Statistics
  Objects: 4
  Frames:  58
  By type:
    dark: 8
    flat: 4
    light: 42
  Used:      24.3 GB
  Available: 1.2 TB
```

---

### `archive_remove`

Removes a frame from the archive by its UUID.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | string | ✓ | Archive frame UUID (from `archive_find`) |
| `delete_file` | boolean | | Also delete the FITS file from disk (default `false`) |

Example:
```
archive_remove(id="A3F2B1C0-...", delete_file=false)
```

---

### `archive_reject`

Marks a frame as rejected so it is excluded from processing queries, or clears that flag.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | string | ✓ | Archive frame UUID (from `archive_find`) |
| `reason` | string | | Optional description of why the frame was rejected |
| `undo` | boolean | | Set to `true` to clear the rejection flag (default `false`) |

Rejected frames are excluded from all `archive_find` calls by default. They stay in the database and can be reviewed with `archive_find(rejected_only=true)`.

Examples:
```
archive_reject(id="A3F2B1C0-...", reason="telescope moved mid-exposure")
archive_reject(id="A3F2B1C0-...", undo=true)
```

---

### `archive_update_quality`

Manually sets or corrects quality metrics for an archived frame. Only supplied fields are updated; omitted fields are left unchanged.

Quality metrics are normally populated automatically when you run an analysis pipeline (`star_detection`, `frame_registration`, `frame_stacking`, `optical_quality`) via `run_pipeline`. Use this tool to set or correct them manually — for example to import measurements from external software.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | string | ✓ | Archive frame UUID (from `archive_find`) |
| `star_count` | integer | | Number of detected stars |
| `median_fwhm` | number | | Median FWHM in pixels (average of major and minor axes) |
| `median_eccentricity` | number | | Median star eccentricity (0=circular; lower is rounder, indicating better tracking and focus) |
| `background_noise` | number | | Normalised background noise level (0–1) |

Examples:
```
archive_update_quality(id="A3F2B1C0-...", star_count=312, median_fwhm=3.85, median_eccentricity=0.312)
archive_update_quality(id="A3F2B1C0-...", background_noise=0.0028)
```

Response:
```
Updated quality metrics for frame A3F2B1C0-...: star_count=312, median_fwhm=3.850px, median_eccentricity=0.312.
```

---

## Frame set tools

Frame sets are named, homogeneous collections of archived frames. All members share the same frame type, processing level, and optical filter. They serve as inputs to processing pipelines and as calibration references for future processed frames.

### `archive_frameset_inspect`

Dry-run: shows which frames would form a frame set and reports property distributions (cameras, filters, date span, temperature range, pixel scales, position angles) **without writing anything**. Use this before `archive_frameset_create` to verify frame compatibility.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `frame_type` | string | | Frame type: `"light"`, `"dark"`, `"flat"`, `"bias"` |
| `object_name` | string | | Partial object name match |
| `filters` | array | | Optical filters to include |
| `camera` | string | | Camera name (exact match) |
| `from_date` | string | | Start date `YYYY-MM-DD` |
| `to_date` | string | | End date `YYYY-MM-DD` |
| `processing_level` | string | | `"raw"`, `"calibrated"`, `"stacked"`, or `"stretched"` |
| `calibrated` | boolean | | Only calibrated frames |
| `temp_center` | number | | Centre temperature in °C for dark frame grouping |
| `temp_tolerance` | number | | Temperature tolerance ±°C (default `2.0`) |
| `max_fwhm` | number | | Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded. |
| `min_stars` | integer | | Only frames with at least this many detected stars. Frames without quality data are excluded. |
| `max_background_noise` | number | | Only frames with background noise ≤ this value (0–1). Frames without quality data are excluded. |
| `max_eccentricity` | number | | Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded. |

Example:
```
archive_frameset_inspect(frame_type="light", object_name="M51", filters=["Ha"])
```

Response:
```
Dry-run inspection — 18 frame(s) matched
────────────────────────────────────────────────────────────
  Frame type:    ✓ light (18)
  Filter:        ✓ Ha (18)
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
  a1b2c3d4-...                          M51             Ha            300s  2024-03-15
  …
```

---

### `archive_frameset_create`

Creates a frame set from all non-rejected frames matching a query. Errors if the query returns frames with mixed types or mixed processing levels. Mixed optical filters are blocked by default — set `force=true` to allow them (stored as a comma-separated list). Always returns the inspection report alongside the new frame set.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `name` | string | | Name for the frame set (auto-generated from query if omitted) |
| `frame_type` | string | | Frame type: `"light"`, `"dark"`, `"flat"`, `"bias"` |
| `object_name` | string | | Partial object name match |
| `filters` | array | | Optical filters to include |
| `camera` | string | | Camera name (exact match) |
| `from_date` | string | | Start date `YYYY-MM-DD` |
| `to_date` | string | | End date `YYYY-MM-DD` |
| `processing_level` | string | | `"raw"`, `"calibrated"`, `"stacked"`, or `"stretched"` |
| `calibrated` | boolean | | Only calibrated frames |
| `temp_center` | number | | Centre temperature in °C for dark frame grouping |
| `temp_tolerance` | number | | Temperature tolerance ±°C (default `2.0`) |
| `max_fwhm` | number | | Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded. |
| `min_stars` | integer | | Only frames with at least this many detected stars. Frames without quality data are excluded. |
| `max_background_noise` | number | | Only frames with background noise ≤ this value (0–1). Frames without quality data are excluded. |
| `max_eccentricity` | number | | Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded. |
| `force` | boolean | | Allow mixed optical filters; stored as comma-separated list (default `false`) |

Shared properties (object, filter, camera, exposure, temperature range, date span, pixel scale, focal length, position angle) are recorded automatically on the set; any property that differs across members is left blank.

Examples:
```
archive_frameset_create(frame_type="light", object_name="M51", filters=["Ha"])
archive_frameset_create(name="M51 Ha 2024", frame_type="light", object_name="M51",
                        filters=["Ha"], from_date="2024-01-01", to_date="2024-12-31")
archive_frameset_create(frame_type="dark", temp_center=-10.0, temp_tolerance=2.0)
archive_frameset_create(frame_type="light", object_name="M51", force=true)
```

Response:
```
Created frame set 'M51 Ha'  [A3F2B1C0-...]

Frame set properties:
────────────────────────────────────────────────────────────
  Frame type:    ✓ light (18)
  Filter:        ✓ Ha (18)
  Processing:    ✓ raw (18)
  Object:        ✓ M51 (18)
  Camera:        ✓ ZWO ASI294MC Pro (18)
  …

  Created: 2026-05-25T10:00:00Z
```

---

### `archive_frameset_list`

Lists all frame sets with their member counts. No arguments.

Response:
```
Frame sets (3):
  { id: A3F2B1C0-..., name: M51 Ha, type: light, frames: 18, level: raw, object: M51, filter: Ha, created: 2026-05-25 }
  { id: B4E3D2F1-..., name: Darks -10°C, type: dark, frames: 20, level: raw, created: 2026-05-25 }
  { id: C5F4E3D2-..., name: Flats Ha, type: flat, frames: 10, level: raw, created: 2026-05-25 }
```

---

### `archive_frameset_get`

Returns full details of a frame set, including all member frames.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | string | ✓ | Frame set UUID (from `archive_frameset_list`) |

Example:
```
archive_frameset_get(id="A3F2B1C0-...")
```

Response:
```
Frame Set  A3F2B1C0-...
────────────────────────────────────────────────────────────
  Name:          M51 Ha
  Type:          light
  Level:         raw
  Frames:        18
  Object:        M51
  Filter:        Ha
  Camera:        ZWO ASI294MC Pro
  Exposure:      300 s
  Temperature:   -10.0 – -9.8 °C (mean -9.9)
  Pixel scale:   1.240 "/px
  Focal length:  800 mm
  Date span:     2024-03-15 – 2024-11-22
  Created:       2026-05-25T10:00:00Z

Members:
  { id: a1b2c3d4-..., type: light, object: M51, filter: Ha, exp: 300s, date: 2024-03-15 }
  { id: b2c3d4e5-..., type: light, object: M51, filter: Ha, exp: 300s, date: 2024-03-16 }
  …
```

---

### `archive_frameset_delete`

Deletes a frame set. Member frames are **not** removed from the archive.

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `id` | string | ✓ | Frame set UUID |

---

## Protocol details

- Transport: **stdio** (newline-delimited JSON-RPC 2.0)
- MCP protocol version: `2024-11-05`
- Capabilities: `tools`

## Requirements

- macOS 26+
- CFITSIO installed (`brew install cfitsio`)
- A Mac with a Metal-capable GPU (required for image processing)
