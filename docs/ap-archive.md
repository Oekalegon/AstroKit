# ap-archive — AstrophotoKit Archive CLI

`ap-archive` manages a local FITS archive: ingests frames, indexes their metadata in SQLite, and lets you query by object, coordinates, frame type, filter, date, and processing level.

## Installation

```bash
swift build -c release --product ap-archive
cp .build/release/ap-archive /usr/local/bin/ap-archive
```

Or use the installer (installs `ap`, `ap-archive`, and `astrokit-mcp` in one step):

```bash
./install.sh
```

## Archive location

All commands read the archive root from the `ASTROARCHIVE_PATH` environment variable, or from the `--archive-path` flag.

```bash
export ASTROARCHIVE_PATH=~/AstroArchive
```

The archive root contains:
- `archive.db` — SQLite database with frame metadata and spatial index
- Optionally, FITS files organised into subfolders when `--copy` is used

---

## Commands

### `ap-archive add`

Adds one or more FITS files to the archive. Reads metadata automatically from FITS headers (`OBJECT`, `RA`, `DEC`, `IMAGETYP`, `FILTER`, `INSTRUME`, `DATE-OBS`, `EXPTIME`, `GAIN`, `CCD-TEMP`, …).

```
ap-archive add <path> [--recursive] [--copy] [--json]
```

| Flag | Description |
|------|-------------|
| `--recursive` | Recurse into subdirectories (when path is a directory) |
| `--copy` | Copy files into the archive folder hierarchy (`<root>/<object>/<date>/<type>/<filter>/`) |
| `--json` | Print results as JSON |

**Examples:**

```bash
# Index a single file in place (no copy):
ap-archive add ~/lights/M51_Ha_300s.fits

# Index an entire directory in place:
ap-archive add ~/lights/

# Copy all FITS files in a directory tree into the archive:
ap-archive add ~/lights/ --recursive --copy

# JSON output for scripting:
ap-archive add ~/lights/ --json
```

**Example output:**

```
Added 5 frame(s) to the archive.
  light [Ha] 300s M51  /path/to/M51_Ha_001.fits
  light [Ha] 300s M51  /path/to/M51_Ha_002.fits
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
| `--type <types>` | Comma-separated frame types: `light,dark,flat,bias` |
| `--filter <filters>` | Comma-separated filters: `Ha,SII,OIII,R,G,B,L` |
| `--from <date>` | Start date in `YYYY-MM-DD` format |
| `--to <date>` | End date in `YYYY-MM-DD` format |
| `--level <level>` | Processing level: `raw`, `calibrated`, `stacked`, `stretched` |
| `--calibrated` | Only calibrated frames |
| `--stacked` | Only stacked frames |
| `--ra <deg>` | Cone search centre RA (degrees) |
| `--dec <deg>` | Cone search centre Dec (degrees) |
| `--radius <deg>` | Cone search radius (degrees) |
| `--limit <n>` | Maximum number of results |
| `--json` | Print results as JSON |

**Examples:**

```bash
# All light frames of M51:
ap-archive find --object M51 --type light

# Hα and SII lights taken in 2024:
ap-archive find --type light --filter Ha,SII --from 2024-01-01 --to 2024-12-31

# All frames within 1° of RA=202.47°, Dec=+47.20° (M51):
ap-archive find --ra 202.47 --dec 47.20 --radius 1.0

# Most recent 20 stacked frames:
ap-archive find --stacked --limit 20
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
      Ha          18
      OIII        12
      SII         12

  Disk used:      24.3 GB
  Disk available: 1.2 TB
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
| `DATE-OBS`, `DATE-BEG` | Observation timestamp |
| `EXPTIME`, `EXPOSURE` | Exposure time (s) |
| `GAIN` | Camera gain |
| `OFFSET`, `PEDESTAL` | Camera offset |

Processing level is inferred from `IMAGETYP` and custom keywords (`CALIBRAT`, `STACKED`, `STRETCHD`).

### Coordinate search

Right ascension and declination are indexed using [HEALPix](https://healpix.sourceforge.io) at nside=64 (~55 arcmin resolution). Cone searches (`--ra`, `--dec`, `--radius`) use this index for fast spatial lookup.

### Folder structure

When `--copy` is used, files are placed under:

```
<archive-root>/<object>/<YYYY-MM-DD>/<frame-type>/<filter>/<filename>.fits
```

For example: `~/AstroArchive/M51/2024-03-15/light/Ha/M51_Ha_300s_001.fits`

### Schema migrations

The archive database applies schema migrations automatically on open using `PRAGMA user_version`. Existing archives upgrade safely when a new version of `ap-archive` is installed.

## Requirements

- macOS 26+
- CFITSIO installed (`brew install cfitsio`)
